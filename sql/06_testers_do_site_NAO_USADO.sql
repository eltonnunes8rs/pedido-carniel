-- Libera o SITE só para alguns clientes (testers), independente do robô do WhatsApp.
-- app_acesso = LISTA  -> só os telefones da lista entram e pedem pelo site
-- app_acesso = TODOS  -> qualquer cliente
-- Esta versão já deixa em LISTA (só você e os testers que cadastrar).

CREATE TABLE IF NOT EXISTS carniel_app_liberados (
  tel8      text PRIMARY KEY,        -- últimos 8 dígitos do celular
  nome      text,
  ativo     boolean NOT NULL DEFAULT true,
  criado_em timestamptz NOT NULL DEFAULT now()
);

INSERT INTO carniel_config (chave, valor, descricao)
VALUES ('app_acesso', 'LISTA', 'Site de pedidos: LISTA = só telefones de carniel_app_liberados; TODOS = qualquer cliente.')
ON CONFLICT (chave) DO NOTHING;

-- você (teste) já liberado
INSERT INTO carniel_app_liberados (tel8, nome) VALUES ('00000000', 'Elton (teste)')
ON CONFLICT (tel8) DO UPDATE SET ativo = true;

CREATE OR REPLACE FUNCTION app_liberado_carniel(p_tel text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT upper(btrim(valor)) FROM carniel_config WHERE chave = 'app_acesso' LIMIT 1), 'TODOS') <> 'LISTA'
      OR EXISTS (SELECT 1 FROM carniel_app_liberados l
                  WHERE l.ativo AND l.tel8 = right(regexp_replace(COALESCE(p_tel, ''), '\D', '', 'g'), 8));
$$;

-- 1) pedir código: quem não está liberado recebe motivo 'nao_liberado' (nenhum código é gerado nem enviado)
CREATE OR REPLACE FUNCTION public.app_pedir_codigo_carniel(p_tel text)
 RETURNS TABLE(r_ok boolean, r_codigo text, r_tel_envio text, r_motivo text)
 LANGUAGE plpgsql
AS $function$
-- VERSÃO 22/11/2026 (lista de testers) — antes: 22/11/2026 18:40
DECLARE
    v_tel text := app_tel_limpo_carniel(p_tel);
    v_t8  text;
    v_cod text;
    v_env text;
BEGIN
    IF v_tel IS NULL THEN
        RETURN QUERY SELECT false, NULL::text, NULL::text, 'telefone_invalido'::text; RETURN;
    END IF;
    IF NOT app_liberado_carniel(v_tel) THEN
        RETURN QUERY SELECT false, NULL::text, NULL::text, 'nao_liberado'::text; RETURN;
    END IF;
    v_t8 := right(v_tel, 8);
    IF (SELECT count(*) FROM carniel_app_codigos c WHERE c.tel8 = v_t8 AND c.criado_em > now() - interval '1 hour') >= 3 THEN
        RETURN QUERY SELECT false, NULL::text, NULL::text, 'muitos_codigos'::text; RETURN;
    END IF;
    IF (SELECT count(*) FROM carniel_app_codigos c WHERE c.criado_em > now() - interval '1 hour') >= 60 THEN
        RETURN QUERY SELECT false, NULL::text, NULL::text, 'limite_geral'::text; RETURN;
    END IF;

    v_cod := lpad(((('x' || substr(md5(gen_random_uuid()::text), 1, 7))::bit(28))::int % 1000000)::text, 6, '0');

    SELECT cl.telefone_whatsapp INTO v_env
      FROM carniel_clientes cl
     WHERE right(regexp_replace(COALESCE(cl.telefone_whatsapp, ''), '\D', '', 'g'), 8) = v_t8
     ORDER BY cl.data_ultimo_pedido DESC NULLS LAST, cl.id DESC LIMIT 1;

    INSERT INTO carniel_app_codigos (tel, tel8, hash, expira_em)
    VALUES (v_tel, v_t8, md5(v_cod || ':' || v_t8 || ':carniel-app'), now() + interval '10 minutes');

    RETURN QUERY SELECT true, v_cod, COALESCE(v_env, v_tel), NULL::text;
END
$function$;

-- 2) sessão: se alguém for tirado da lista, a sessão dele deixa de valer na hora (cardápio, pedido, tudo)
CREATE OR REPLACE FUNCTION public.app_sessao_carniel(p_token text)
 RETURNS TABLE(r_ok boolean, r_cliente_id integer, r_tel text, r_nome text, r_convenio boolean)
 LANGUAGE plpgsql
AS $function$
-- VERSÃO 22/11/2026 (lista de testers) — antes: 22/11/2026 18:40
BEGIN
    RETURN QUERY
    SELECT true, s.cliente_id, s.tel, cl.nome::text, cl.convenio
      FROM carniel_app_sessoes s JOIN carniel_clientes cl ON cl.id = s.cliente_id
     WHERE s.token_hash = md5(COALESCE(p_token, '')) AND s.ativo AND s.expira_em > now()
       AND app_liberado_carniel(s.tel);
    IF FOUND THEN
        UPDATE carniel_app_sessoes SET ultimo_uso = now() WHERE token_hash = md5(p_token);
    ELSE
        RETURN QUERY SELECT false, NULL::integer, NULL::text, NULL::text, NULL::boolean;
    END IF;
END
$function$;

-- ===== COMO USAR =====
-- Liberar um tester (últimos 8 dígitos do celular):
--   INSERT INTO carniel_app_liberados (tel8, nome) VALUES ('99999999', 'Fulana') ON CONFLICT (tel8) DO UPDATE SET ativo = true;
-- Tirar:   UPDATE carniel_app_liberados SET ativo = false WHERE tel8 = '99999999';
-- Ver:     SELECT * FROM carniel_app_liberados ORDER BY criado_em;
-- Abrir para todos:   UPDATE carniel_config SET valor = 'TODOS' WHERE chave = 'app_acesso';
-- Voltar a só testers: UPDATE carniel_config SET valor = 'LISTA' WHERE chave = 'app_acesso';
-- Teste: SELECT app_liberado_carniel('5549900000000');  -- true
--        SELECT app_liberado_carniel('5549911112222');  -- false (enquanto em LISTA)
