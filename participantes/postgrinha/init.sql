-- Definição de tabelas idêntica ao exemplo
CREATE TABLE clientes (
	id SERIAL PRIMARY KEY,
	nome VARCHAR(50) NOT NULL,
	limite INTEGER NOT NULL
);

CREATE TABLE transacoes (
	id SERIAL PRIMARY KEY,
	cliente_id INTEGER NOT NULL,
	valor INTEGER NOT NULL,
	tipo CHAR(1) NOT NULL,
	descricao VARCHAR(10) NOT NULL,
	realizada_em TIMESTAMP NOT NULL DEFAULT NOW(),
	CONSTRAINT fk_clientes_transacoes_id
		FOREIGN KEY (cliente_id) REFERENCES clientes(id)
);

CREATE TABLE saldos (
	id SERIAL PRIMARY KEY,
	cliente_id INTEGER NOT NULL,
	valor INTEGER NOT NULL,
	CONSTRAINT fk_clientes_saldos_id
		FOREIGN KEY (cliente_id) REFERENCES clientes(id)
);

CREATE FUNCTION clear_old_transactions(cid INTEGER) RETURNS void 
LANGUAGE plpgsql AS $$
DECLARE
	_n_transacoes INTEGER;
BEGIN
	SELECT COUNT(*) INTO _n_transacoes
	FROM transacoes
	WHERE cliente_id = cid;
	
	-- Armazena até 100 transações antes de apagar para tentar manter o desempenho
	IF _n_transacoes > 100 THEN
		DELETE FROM transacoes
		WHERE id IN (
			SELECT id FROM transacoes
			WHERE cliente_id = cid
			ORDER BY realizada_em DESC
			OFFSET 10
		);
	END IF;
END
$$;

-- Funções da API
CREATE SCHEMA api;

CREATE FUNCTION api.reset() RETURNS void 
LANGUAGE plpgsql AS $$
BEGIN
	TRUNCATE TABLE clientes RESTART IDENTITY CASCADE;
	INSERT INTO clientes (nome, limite)
	VALUES
		('o barato sai caro', 1000 * 100),
		('zan corp ltda', 800 * 100),
		('les cruders', 10000 * 100),
		('padaria joia de cocaia', 100000 * 100),
		('kid mais', 5000 * 100);

	INSERT INTO saldos (cliente_id, valor)
		SELECT id, 0 FROM clientes;
END;
$$;

CREATE FUNCTION api.extrato(cid INTEGER) RETURNS JSON
LANGUAGE plpgsql AS $$
DECLARE
	_result JSON;
BEGIN
	IF NOT EXISTS (SELECT 1 FROM clientes WHERE id = cid) THEN
		RAISE sqlstate 'PGRST' USING
			message = '{"code":"404","message":"Cliente inexistente"}',
			detail = '{"status":404,"headers":{}}';
	END IF;

	PERFORM clear_old_transactions(cid);

	SELECT json_build_object(
			'saldo', json_build_object(
				'total', s.valor,
				'data_extrato', now(),
				'limite', c.limite
			),
			'ultimas_transacoes', COALESCE(json_agg(
                json_build_object(
                    'valor', t.valor,
                    'tipo', t.tipo,
                    'descricao', t.descricao,
                    'realizada_em', t.realizada_em
                ) ORDER BY t.realizada_em DESC
            ) FILTER (WHERE t.id IS NOT NULL), '[]')
		) INTO _result
	FROM
		clientes c
    LEFT JOIN
        saldos s ON c.id = s.cliente_id
    LEFT JOIN LATERAL (
        SELECT * FROM transacoes
        WHERE cliente_id = c.id
        ORDER BY realizada_em DESC
        LIMIT 10
    ) t ON true
	WHERE
		c.id = cid
	GROUP BY
		c.id, s.valor, c.limite;

	RETURN _result;
END;$$;

CREATE FUNCTION api.transacoes(JSON) RETURNS JSON
LANGUAGE plpgsql AS $$
DECLARE
    _saldo INTEGER;
    _limite INTEGER;
	_cid INTEGER;
	_valor INTEGER;
	_descricao VARCHAR(10);
	_tipo CHAR(1);
	_n_transacoes INTEGER;
BEGIN
	SELECT current_setting('request.headers', true)::json->>'cid' INTO _cid;

	-- Verifica se o cliente existe
	IF NOT EXISTS (SELECT 1 FROM clientes WHERE id = _cid) THEN
		RAISE sqlstate 'PGRST' USING
			message = '{"code":"404","message":"Cliente inexistente"}',
			detail = '{"status":404,"headers":{}}';
	END IF;

	-- Validação de campos
	IF NOT ($1::json->>'valor' is not NULL and
	        $1::json->>'tipo' is not NULL and
			$1::json->>'descricao' is not NULL) THEN
		RAISE sqlstate 'PGRST' USING
			message = '{"code":"422","message":"Campos obrigatórios não informados"}',
			detail = '{"status":422,"headers":{}}';
	END IF;

	IF NOT ($1::json->>'valor' ~ '^[0-9]+$') THEN
		RAISE sqlstate 'PGRST' USING
			message = '{"code":"422","message":"Valor invalido"}',
			detail = '{"status":422,"headers":{}}';
	END IF;

	IF NOT ($1::json->>'tipo' ~ '^[cd]$') THEN
		RAISE sqlstate 'PGRST' USING
			message = '{"code":"422","message":"Tipo invalido"}',
			detail = '{"status":422,"headers":{}}';	
	END IF;

	IF NOT ($1::json->>'descricao' ~ '^.{1,10}$') THEN
		RAISE sqlstate 'PGRST' USING
			message = '{"code":"422","message":"Descricao invalida"}',
			detail = '{"status":422,"headers":{}}';
	END IF;


    _valor := ($1::json->>'valor')::int;
	_descricao := $1::json->>'descricao';
	_tipo := $1::json->>'tipo';

    SELECT s.valor, c.limite INTO _saldo, _limite
    FROM saldos s
    JOIN clientes c ON s.cliente_id = c.id
    WHERE s.cliente_id = _cid;

    IF _tipo = 'c' THEN
        _saldo := _saldo + _valor;
    ELSE
        _saldo := _saldo - _valor;
    END IF;

	-- Verifica se o limite é suficiente
    IF _saldo + _limite < 0 THEN
		RAISE sqlstate 'PGRST' USING
			message = '{"code":"422","message":"Limite insuficiente"}',
			detail = '{"status":422,"headers":{}}';
    END IF;

	-- Atualiza o saldo
    UPDATE saldos SET valor = _saldo WHERE cliente_id = _cid;

	-- Insere a transação no histórico
    INSERT INTO transacoes (cliente_id, valor, tipo, descricao)
    VALUES (_cid, _valor, _tipo, _descricao);

	-- Apaga transações antigas para esse cliente
	PERFORM clear_old_transactions(_cid);

	-- Retorna o saldo atual segundo a spec
    RETURN json_build_object('limite', _limite, 'saldo', _saldo);
END;$$;

-- Setup de acesso
create role rest noinherit login password '123';

-- Role WWW
CREATE ROLE www nologin;
grant www to rest;

GRANT USAGE ON SCHEMA api TO www;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO www;
GRANT SELECT, UPDATE ON saldos TO www;
GRANT SELECT, INSERT, DELETE ON transacoes TO www;
GRANT SELECT ON clientes TO www;

-- Role RESETER (para resetar o banco sem reiniciar)
CREATE ROLE reseter nologin;
GRANT reseter TO rest;

GRANT USAGE ON SCHEMA api TO reseter;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO reseter;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO reseter;
ALTER TABLE clientes OWNER TO reseter;
ALTER TABLE transacoes OWNER TO reseter;
ALTER TABLE saldos OWNER TO reseter;
ALTER SEQUENCE clientes_id_seq OWNER TO reseter;
ALTER SEQUENCE transacoes_id_seq OWNER TO reseter;
ALTER SEQUENCE saldos_id_seq OWNER TO reseter;

-- Reseta o banco para o estado inicial
DO $$ BEGIN PERFORM api.reset(); END; $$;


