-- 14 — Aba "Cardápio do dia" (só ADMIN) — 25/11/2026
-- Cria: secao_cardapio_carniel, app_admin_ok_carniel, mensagem_cardapio_dia_carniel,
--       app_admin_cardapio_dados_carniel, app_admin_cardapio_salvar_carniel
-- Não altera nada existente. Desfazer: DROP FUNCTION das 5 funções abaixo.

-- 1) tipo gravado no banco -> seção da aba (NULL = não mexe: bebidas, sabadou, ofertas...)
CREATE OR REPLACE FUNCTION secao_cardapio_carniel(p_tipo text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE
  WHEN upper(p_tipo) = 'CARDAPIO' THEN 'BUFFET'
  WHEN upper(p_tipo) = 'CARNES' THEN 'CARNES'
  WHEN upper(p_tipo) = 'SALADAS' THEN 'SALADAS'
  WHEN upper(p_tipo) IN ('TAPIOCA','TAPIOCAS') THEN 'TAPIOCAS'
  WHEN upper(p_tipo) = 'PIZZA' OR upper(p_tipo) LIKE 'PIZZA\_CRUA%' THEN 'PIZZA'
  WHEN upper(p_tipo) IN ('METEORO','MARMITA_METEORO','METEORO_DA_PAIXAO_X_SALADA') THEN 'METEORO'
  WHEN upper(p_tipo) IN ('FIT_DO_DIA','MARMITA_FIT','MARMITA FIT','MARMITA_FIT_DO_DIA') THEN 'FIT'
  WHEN upper(p_tipo) IN ('BOA_DO_DIA','MARMITA','MARMITA_BOA') THEN 'BOA'
  WHEN upper(p_tipo) IN ('ECONOMICA','MARMITA_ECONOMICA') THEN 'ECON'
  ELSE NULL END
$$;

-- 2) o token é de um ADMIN ativo?
CREATE OR REPLACE FUNCTION app_admin_ok_carniel(p_token text) RETURNS boolean
LANGUAGE sql AS $$
 SELECT EXISTS (
   SELECT 1 FROM app_sessao_carniel(p_token) s
   JOIN carniel_usuarios u ON right(regexp_replace(u.telefone_whatsapp,'\D','','g'),8) = right(regexp_replace(COALESCE(s.r_tel,''),'\D','','g'),10)
   WHERE s.r_ok AND u.ativo AND upper(u.perfil)='ADMIN')
$$;

-- 3) mensagem do WhatsApp a partir do dia gravado
CREATE OR REPLACE FUNCTION mensagem_cardapio_dia_carniel(p_data date) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  v_dias text[] := ARRAY['DOMINGO','SEGUNDA-FEIRA','TERÇA-FEIRA','QUARTA-FEIRA','QUINTA-FEIRA','SEXTA-FEIRA','SÁBADO'];
  v_txt text; v_bloco text; v_sabores text;
  r record;
BEGIN
  v_txt := 'Bom diaaaaa! ☀️' || E'\n\n' ||
           '*CARDÁPIO COMPLETO DE ' || v_dias[extract(dow FROM p_data)::int + 1] || ' – ' || to_char(p_data,'DD/MM/YYYY') || '*';

  FOR r IN SELECT * FROM (VALUES
      ('BUFFET','🍽️ *BUFFET*',1),('CARNES','🥩 *CARNES*',2),
      ('SALADAS','🥗 *SALADAS E COMPLEMENTOS FRIOS*',3),('TAPIOCAS','🫓 *TAPIOCAS E FRUTAS*',4)) t(k,titulo,o) ORDER BY o LOOP
    SELECT string_agg('• ' || p.nome || COALESCE(' (' || NULLIF(i.observacao,'') || ')',''), E'\n' ORDER BY c.id, i.ordem)
      INTO v_bloco
      FROM carniel_dias d JOIN carniel_dia_config c ON c.dia_id=d.id AND c.ativo
      JOIN carniel_dia_config_itens i ON i.config_id=c.id AND i.ativo
      JOIN carniel_produtos p ON p.id=i.produto_id
     WHERE d.data_dia=p_data AND secao_cardapio_carniel(c.tipo)=r.k;
    IF v_bloco IS NOT NULL THEN v_txt := v_txt || E'\n\n' || r.titulo || E'\n' || v_bloco; END IF;
  END LOOP;

  SELECT string_agg(p.nome, ', ' ORDER BY i.ordem) INTO v_sabores
    FROM carniel_dias d JOIN carniel_dia_config c ON c.dia_id=d.id AND c.ativo
    JOIN carniel_dia_config_itens i ON i.config_id=c.id AND i.ativo
    JOIN carniel_produtos p ON p.id=i.produto_id
   WHERE d.data_dia=p_data AND secao_cardapio_carniel(c.tipo)='PIZZA';
  IF v_sabores IS NOT NULL THEN
    IF position(', ' IN v_sabores) > 0 THEN
      v_sabores := regexp_replace(v_sabores, ', ([^,]*)$', ' e \1');
    END IF;
    v_txt := v_txt || E'\n\n🍕 *PIZZA CRUA OU ASSADA – R$ 40,00*' || E'\nSabores: ' || lower(v_sabores) || '.';
  END IF;

  v_bloco := NULL;
  FOR r IN SELECT * FROM (VALUES
      ('METEORO','☄️ *Meteoro da Paixão*',1),('FIT','💪 *Fit do Dia*',2),
      ('BOA','😋 *Boa do Dia*',3),('ECON','💰 *Econômica*',4)) t(k,titulo,o) ORDER BY o LOOP
    DECLARE v_it text; BEGIN
      SELECT string_agg(p.nome || COALESCE(' (' || NULLIF(i.observacao,'') || ')',''), ', ' ORDER BY i.ordem)
        INTO v_it
        FROM carniel_dias d JOIN carniel_dia_config c ON c.dia_id=d.id AND c.ativo
        JOIN carniel_dia_config_itens i ON i.config_id=c.id AND i.ativo
        JOIN carniel_produtos p ON p.id=i.produto_id
       WHERE d.data_dia=p_data AND secao_cardapio_carniel(c.tipo)=r.k;
      IF v_it IS NOT NULL THEN
        v_bloco := COALESCE(v_bloco || E'\n','') || r.titulo || E'\n' || v_it;
      END IF;
    END;
  END LOOP;
  IF v_bloco IS NOT NULL THEN
    v_txt := v_txt || E'\n\n🍱 *MARMITAS*\n' || v_bloco;
  END IF;

  RETURN v_txt;
END $$;

-- 4) dados da tela (itens por seção, já com marcações sugeridas)
CREATE OR REPLACE FUNCTION app_admin_cardapio_dados_carniel(p_token text, p_data date DEFAULT NULL, p_copiar_de date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_data date := COALESCE(p_data, (now() AT TIME ZONE 'America/Sao_Paulo')::date);
  v_dow int := extract(dow FROM v_data)::int;
  v_lim_fixo numeric := 0.80;   -- sempre marcado
  v_lim_fixo_grupo numeric := 0.50; -- tapiocas / pizza / econômica
  v_lim_dia numeric := 0.75;    -- marcado pelo dia da semana
  v_min_dias int := 4;          -- mínimo de dias do mesmo dia da semana p/ confiar
  v_janela int := 180;
  v_fonte date;
  v_salvo boolean;
  v_res jsonb;
BEGIN
  IF NOT app_admin_ok_carniel(p_token) THEN
    RETURN jsonb_build_object('ok', false, 'erro', 'sem_permissao');
  END IF;

  v_salvo := EXISTS (SELECT 1 FROM carniel_dias d JOIN carniel_dia_config c ON c.dia_id=d.id AND c.ativo
                      WHERE d.data_dia=v_data AND secao_cardapio_carniel(c.tipo) IS NOT NULL);
  v_fonte := CASE WHEN p_copiar_de IS NOT NULL THEN p_copiar_de WHEN v_salvo THEN v_data ELSE NULL END;

  WITH base AS (
    SELECT d.data_dia, secao_cardapio_carniel(c.tipo) s, i.produto_id, NULLIF(i.observacao,'') obs
      FROM carniel_dias d JOIN carniel_dia_config c ON c.dia_id=d.id AND c.ativo
      JOIN carniel_dia_config_itens i ON i.config_id=c.id AND i.ativo
     WHERE secao_cardapio_carniel(c.tipo) IS NOT NULL
       AND d.data_dia < v_data AND d.data_dia >= v_data - v_janela),
  dias AS (SELECT s, count(DISTINCT data_dia) n,
                  count(DISTINCT data_dia) FILTER (WHERE extract(dow FROM data_dia)::int = v_dow) nd
             FROM base GROUP BY s),
  uso AS (SELECT s, produto_id, count(DISTINCT data_dia) u,
                 count(DISTINCT data_dia) FILTER (WHERE extract(dow FROM data_dia)::int = v_dow) ud,
                 max(data_dia) visto,
                 (array_agg(obs ORDER BY data_dia DESC) FILTER (WHERE obs IS NOT NULL))[1] obs
            FROM base GROUP BY s, produto_id),
  fonte AS (SELECT secao_cardapio_carniel(c.tipo) s, i.produto_id, NULLIF(i.observacao,'') obs, i.ordem
              FROM carniel_dias d JOIN carniel_dia_config c ON c.dia_id=d.id AND c.ativo
              JOIN carniel_dia_config_itens i ON i.config_id=c.id AND i.ativo
             WHERE d.data_dia = v_fonte AND secao_cardapio_carniel(c.tipo) IS NOT NULL),
  itens AS (
    SELECT u.s, p.id, p.nome, u.visto, u.u, u.ud, di.n, di.nd,
           round(100.0*u.u/NULLIF(di.n,0)) freq,
           CASE WHEN di.nd >= v_min_dias THEN round(100.0*u.ud/di.nd) END freq_dia,
           COALESCE(f.obs, u.obs) obs,
           (f.produto_id IS NOT NULL) na_fonte,
           CASE WHEN u.u::numeric/NULLIF(di.n,0) >= CASE WHEN u.s IN ('TAPIOCAS','PIZZA','ECON') THEN v_lim_fixo_grupo ELSE v_lim_fixo END THEN 'fixo'
                WHEN di.nd >= v_min_dias AND u.ud::numeric/di.nd >= v_lim_dia THEN 'dia'
           END motivo
      FROM uso u JOIN carniel_produtos p ON p.id=u.produto_id AND p.ativo AND p.nome NOT ILIKE 'Sabores:%'
      JOIN dias di ON di.s=u.s
      LEFT JOIN fonte f ON f.s=u.s AND f.produto_id=u.produto_id
    UNION  -- itens da fonte que não estão no histórico da janela
    SELECT f.s, p.id, p.nome, NULL, 0, 0, 0, 0, NULL, NULL, f.obs, true, NULL
      FROM fonte f JOIN carniel_produtos p ON p.id=f.produto_id
     WHERE NOT EXISTS (SELECT 1 FROM uso u WHERE u.s=f.s AND u.produto_id=f.produto_id))
  SELECT jsonb_agg(jsonb_build_object(
           'key', t.k, 'titulo', t.titulo,
           'itens', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'id', x.id, 'nome', x.nome, 'obs', x.obs,
                'marcado', CASE WHEN v_fonte IS NOT NULL THEN x.na_fonte ELSE x.motivo IS NOT NULL END,
                'motivo', x.motivo, 'freq', x.freq, 'freq_dia', x.freq_dia, 'visto', x.visto)
                ORDER BY (CASE WHEN v_fonte IS NOT NULL THEN x.na_fonte ELSE x.motivo IS NOT NULL END) DESC,
                         x.freq DESC NULLS LAST, x.nome)
              FROM itens x WHERE x.s=t.k), '[]'::jsonb))
           ORDER BY t.o)
    INTO v_res
    FROM (VALUES ('BUFFET','Buffet',1),('CARNES','Carnes',2),('SALADAS','Saladas e complementos frios',3),
                 ('TAPIOCAS','Tapiocas e frutas',4),('PIZZA','Pizza – sabores',5),
                 ('METEORO','Meteoro da Paixão',6),('FIT','Fit do Dia',7),('BOA','Boa do Dia',8),('ECON','Econômica',9)) t(k,titulo,o);

  RETURN jsonb_build_object('ok', true, 'data', v_data, 'dow', v_dow, 'salvo', v_salvo,
                            'copiado_de', p_copiar_de, 'secoes', v_res,
                            'mensagem', CASE WHEN v_salvo THEN mensagem_cardapio_dia_carniel(v_data) END);
END $$;

-- 5) salvar o dia. p_secoes: [{"key":"BUFFET","itens":[{"id":1,"obs":null},{"nome":"Maionese nova","obs":null}]}, ...]
CREATE OR REPLACE FUNCTION app_admin_cardapio_salvar_carniel(p_token text, p_data date, p_secoes jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  s jsonb; it jsonb; v_dia int; v_cfg int; v_pid int; v_ord int; v_tot int := 0; v_novos text[] := '{}';
  v_nome text; v_busca text; v_tv text; v_tipo text; v_gnome text;
BEGIN
  IF NOT app_admin_ok_carniel(p_token) THEN
    RETURN jsonb_build_object('ok', false, 'erro', 'sem_permissao');
  END IF;
  IF p_data IS NULL OR p_secoes IS NULL OR jsonb_typeof(p_secoes) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'erro', 'dados_invalidos');
  END IF;

  SELECT count(*) INTO v_tot FROM jsonb_array_elements(p_secoes) a, jsonb_array_elements(COALESCE(a->'itens','[]')) b;
  IF v_tot = 0 THEN RETURN jsonb_build_object('ok', false, 'erro', 'nenhum_item'); END IF;
  v_tot := 0;

  SELECT id INTO v_dia FROM carniel_dias WHERE data_dia = p_data LIMIT 1;
  IF v_dia IS NULL THEN INSERT INTO carniel_dias (data_dia) VALUES (p_data) RETURNING id INTO v_dia; END IF;

  -- apaga só as seções da aba (bebidas e outras ficam)
  DELETE FROM carniel_dia_config c WHERE c.dia_id = v_dia AND secao_cardapio_carniel(c.tipo) IS NOT NULL;

  FOR s IN SELECT * FROM jsonb_array_elements(p_secoes) LOOP
    IF jsonb_array_length(COALESCE(s->'itens','[]')) = 0 THEN CONTINUE; END IF;
    SELECT x.t, x.n INTO v_tipo, v_gnome FROM (VALUES
      ('BUFFET','CARDAPIO','Cardápio Completo'),('CARNES','CARNES','Carnes'),
      ('SALADAS','SALADAS','Saladas e complementos frios'),('TAPIOCAS','TAPIOCAS','Tapiocas e frutas'),
      ('PIZZA','PIZZA','Pizza crua ou assada – R$ 40,00'),('METEORO','MARMITA_METEORO','Meteoro da Paixão'),
      ('FIT','MARMITA_FIT','Fit do Dia'),('BOA','MARMITA','Boa do Dia'),('ECON','MARMITA_ECONOMICA','Econômica')
    ) x(k,t,n) WHERE x.k = s->>'key';
    IF v_tipo IS NULL THEN CONTINUE; END IF;

    INSERT INTO carniel_dia_config (dia_id, tipo, nome, ativo) VALUES (v_dia, v_tipo, v_gnome, true) RETURNING id INTO v_cfg;
    v_ord := 0;
    FOR it IN SELECT * FROM jsonb_array_elements(s->'itens') LOOP
      v_pid := NULLIF(it->>'id','')::int;
      IF v_pid IS NULL THEN
        v_nome := regexp_replace(trim(it->>'nome'), '\s+', ' ', 'g');
        IF v_nome IS NULL OR v_nome = '' THEN CONTINUE; END IF;
        v_busca := trim(regexp_replace(lower(regexp_replace(translate(v_nome,
                   'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ','aaaaaeeeeiiiiooooouuuuc' || 'AAAAAEEEEIIIIOOOOOUUUUC'),
                   '[^A-Za-z0-9 ]','','g')),'\s+',' ','g'));
        SELECT id INTO v_pid FROM carniel_produtos WHERE nome_busca = v_busca;
        IF v_pid IS NULL THEN
          SELECT p.tipo_venda INTO v_tv FROM carniel_dia_config c2 JOIN carniel_dia_config_itens i2 ON i2.config_id=c2.id
            JOIN carniel_produtos p ON p.id=i2.produto_id
           WHERE secao_cardapio_carniel(c2.tipo)=s->>'key' GROUP BY p.tipo_venda ORDER BY count(*) DESC LIMIT 1;
          INSERT INTO carniel_produtos (nome, nome_busca, tipo_venda, ativo) VALUES (v_nome, v_busca, COALESCE(v_tv,'KG'), true)
            RETURNING id INTO v_pid;
          v_novos := v_novos || v_nome;
        END IF;
      END IF;
      v_ord := v_ord + 1;
      INSERT INTO carniel_dia_config_itens (config_id, produto_id, ordem, ativo, observacao)
        VALUES (v_cfg, v_pid, v_ord, true, NULLIF(trim(it->>'obs'),''))
        ON CONFLICT (config_id, produto_id) DO NOTHING;
      v_tot := v_tot + 1;
    END LOOP;
  END LOOP;

  UPDATE carniel_dias SET ativo = true WHERE id = v_dia;
  PERFORM garantir_bebidas_dia_carniel(p_data);

  RETURN jsonb_build_object('ok', true, 'itens', v_tot, 'novos', to_jsonb(v_novos),
                            'mensagem', mensagem_cardapio_dia_carniel(p_data));
END $$;

-- Teste (como ADMIN, troque TOKEN por um token de sessão do admin):
-- SELECT app_admin_cardapio_dados_carniel('TOKEN', '2026-11-26');
-- SELECT mensagem_cardapio_dia_carniel('2026-11-25');
