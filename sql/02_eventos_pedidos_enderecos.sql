-- APP PEDIDOS CARNIEL — SQL 02
-- Eventos (métricas), "Meus pedidos" lidos do banco, endereços do cliente.
-- Só CRIA coisas novas. Não altera tabelas/funções existentes. Pode rodar de uma vez.

-- 1) EVENTOS (métricas) -------------------------------------------------------
CREATE TABLE IF NOT EXISTS carniel_app_eventos (
  id         bigserial PRIMARY KEY,
  criado_em  timestamptz NOT NULL DEFAULT now(),
  sessao_dev text,            -- id anônimo do aparelho (gerado no app)
  cliente_id integer,         -- preenchido quando há login
  evento     text NOT NULL,   -- abriu, pediu_codigo, logou, item_add, fechar, enviou, erro, falha_cardapio, clicou_zap...
  dados      jsonb
);
CREATE INDEX IF NOT EXISTS carniel_app_eventos_ev_idx ON carniel_app_eventos (evento, criado_em);
CREATE INDEX IF NOT EXISTS carniel_app_eventos_dev_idx ON carniel_app_eventos (sessao_dev, criado_em);

CREATE OR REPLACE FUNCTION app_evento_carniel(p_token text, p_dev text, p_evento text, p_dados jsonb)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_cli integer;
BEGIN
  IF p_evento IS NULL OR length(p_evento) > 40 THEN RETURN false; END IF;
  IF p_token IS NOT NULL AND p_token <> '' THEN
    SELECT r_cliente_id INTO v_cli FROM app_sessao_carniel(p_token) WHERE r_ok;
  END IF;
  -- trava simples contra abuso: máx. 200 eventos/hora por aparelho
  IF (SELECT count(*) FROM carniel_app_eventos
       WHERE sessao_dev = left(p_dev,64) AND criado_em > now() - interval '1 hour') > 200 THEN
    RETURN false;
  END IF;
  INSERT INTO carniel_app_eventos (sessao_dev, cliente_id, evento, dados)
  VALUES (left(p_dev,64), v_cli, p_evento, p_dados);
  RETURN true;
END $$;

-- 2) ENDEREÇOS DO CLIENTE -----------------------------------------------------
CREATE TABLE IF NOT EXISTS carniel_app_enderecos (
  id          bigserial PRIMARY KEY,
  cliente_id  integer NOT NULL,
  apelido     text NOT NULL,        -- Casa, Trabalho...
  bairro      text,
  endereco    text NOT NULL,
  criado_em   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (cliente_id, apelido)
);

CREATE OR REPLACE FUNCTION app_enderecos_listar_carniel(p_token text)
RETURNS TABLE (r_ok boolean, r_lista jsonb) LANGUAGE plpgsql AS $$
DECLARE v_cli integer;
BEGIN
  SELECT s.r_cliente_id INTO v_cli FROM app_sessao_carniel(p_token) s WHERE s.r_ok;
  IF v_cli IS NULL THEN RETURN QUERY SELECT false, '[]'::jsonb; RETURN; END IF;
  RETURN QUERY SELECT true, COALESCE(
    (SELECT jsonb_agg(jsonb_build_object('apelido',apelido,'bairro',bairro,'endereco',endereco) ORDER BY id)
       FROM carniel_app_enderecos WHERE cliente_id = v_cli), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION app_endereco_salvar_carniel(p_token text, p_apelido text, p_bairro text, p_endereco text)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_cli integer;
BEGIN
  SELECT s.r_cliente_id INTO v_cli FROM app_sessao_carniel(p_token) s WHERE s.r_ok;
  IF v_cli IS NULL OR coalesce(trim(p_apelido),'')='' OR coalesce(trim(p_endereco),'')='' THEN RETURN false; END IF;
  IF (SELECT count(*) FROM carniel_app_enderecos WHERE cliente_id = v_cli) >= 10
     AND NOT EXISTS (SELECT 1 FROM carniel_app_enderecos WHERE cliente_id=v_cli AND apelido=left(trim(p_apelido),40)) THEN
    RETURN false;
  END IF;
  INSERT INTO carniel_app_enderecos (cliente_id, apelido, bairro, endereco)
  VALUES (v_cli, left(trim(p_apelido),40), left(p_bairro,80), left(trim(p_endereco),300))
  ON CONFLICT (cliente_id, apelido) DO UPDATE SET bairro = EXCLUDED.bairro, endereco = EXCLUDED.endereco;
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION app_endereco_apagar_carniel(p_token text, p_apelido text)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_cli integer;
BEGIN
  SELECT s.r_cliente_id INTO v_cli FROM app_sessao_carniel(p_token) s WHERE s.r_ok;
  IF v_cli IS NULL THEN RETURN false; END IF;
  DELETE FROM carniel_app_enderecos WHERE cliente_id = v_cli AND apelido = p_apelido;
  RETURN true;
END $$;

-- 3) MEUS PEDIDOS (status real) -----------------------------------------------
-- Status: CANCELADO (cancelado_em) > ENTREGUE (data_entrega) > EM_PREPARO (já impresso) > RECEBIDO
-- valor_total JÁ inclui a personalizada pesada (conferido no pedido 66: 50 + 8 + 2 = 60).
-- Se Personalizada ainda não foi pesada (valor_personalizada nulo), o app mostra "a confirmar pelo peso".
CREATE OR REPLACE FUNCTION app_meus_pedidos_carniel(p_token text)
RETURNS TABLE (r_ok boolean, r_lista jsonb) LANGUAGE plpgsql AS $$
DECLARE v_cli integer;
BEGIN
  SELECT s.r_cliente_id INTO v_cli FROM app_sessao_carniel(p_token) s WHERE s.r_ok;
  IF v_cli IS NULL THEN RETURN QUERY SELECT false, '[]'::jsonb; RETURN; END IF;
  RETURN QUERY
  SELECT true, COALESCE(jsonb_agg(x ORDER BY (x->>'quando') DESC), '[]'::jsonb)
  FROM (
    SELECT jsonb_build_object(
      'id', p.id,
      'numero', p.numero_preparo,
      'quando', COALESCE(p.data_finalizacao, p.data_pedido::timestamptz),
      'status', CASE
                  WHEN p.cancelado_em IS NOT NULL THEN 'CANCELADO'
                  WHEN p.data_entrega IS NOT NULL THEN 'ENTREGUE'
                  WHEN p.status_impressao = 'IMPRESSO' THEN 'EM_PREPARO'
                  ELSE 'RECEBIDO' END,
      'modo', p.tipo_entrega,
      'pagamento', p.forma_pagamento,
      'taxa', p.taxa_entrega,
      'total', p.valor_total,
      'pesado', (p.valor_personalizada IS NOT NULL),
      'itens', p.itens_pedido
    ) AS x
    FROM carniel_pedidos p
    WHERE p.cliente_id = v_cli
      AND p.data_pedido > now() - interval '30 days'
      AND p.status IN ('FINALIZADO','ENTREGUE','CANCELADO')
    ORDER BY p.id DESC
    LIMIT 20
  ) t;
END $$;

-- TESTE (troque pelo token do seu login, SEM < >):
-- SELECT * FROM app_meus_pedidos_carniel('SEU_TOKEN');
-- SELECT * FROM app_enderecos_listar_carniel('SEU_TOKEN');
-- SELECT app_endereco_salvar_carniel('SEU_TOKEN','Casa','Centro','Rua X, 100');
-- SELECT app_evento_carniel('SEU_TOKEN','teste-dev','abriu','{}');
