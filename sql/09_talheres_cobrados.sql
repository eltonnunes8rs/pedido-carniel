-- APP PEDIDOS CARNIEL — SQL 09: talheres cobrados (R$ 1,00 cada) — SUBSTITUI o 08 (se já rodou o 08, pode rodar este por cima)
-- O site manda "talheres" (0 a 10). Cada talher vira item "Talheres" no pedido (comanda e Meus pedidos) e soma no total.
-- O preço fica em carniel_config.preco_talher (linha abaixo cria com 1,00; para mudar: UPDATE carniel_config SET valor='1.50' WHERE chave='preco_talher').
-- Não apaga nada. Pode rodar de uma vez.

INSERT INTO carniel_config (chave, valor, descricao)
SELECT 'preco_talher', '1.00', 'Preço de cada talher no pedido do site (R$)'
WHERE NOT EXISTS (SELECT 1 FROM carniel_config WHERE chave = 'preco_talher');

CREATE OR REPLACE FUNCTION public.app_pedido_criar_carniel(p_token text, p_dados jsonb)
RETURNS TABLE(r_ok boolean, r_numero integer, r_pedido_id integer, r_motivo text, r_texto text, r_tel text)
LANGUAGE plpgsql AS $f$
-- VERSÃO 22/11/2026 23:45 (talheres R$ 1,00 cada) — antes: 23:10 (frete A COMBINAR) — antes: 22/11/2026 18:40
DECLARE
    s        record;
    r        record;
    it       jsonb;
    v_mid    text;
    v_hoje   date := (now() AT TIME ZONE 'America/Sao_Paulo')::date;
    v_agora  time := (now() AT TIME ZONE 'America/Sao_Paulo')::time;
    v_abre   time;
    v_fecha  time;
    v_teste  boolean;
    v_chave  text := nullif(btrim(COALESCE(p_dados ->> 'chave', '')), '');
    v_exist  integer;
    v_itens  jsonb := '[]'::jsonb;
    v_k      text;
    v_qtd    integer;
    v_obs    text;
    v_preco  numeric;
    v_sub    numeric := 0;
    v_pend   boolean := false;
    v_np     integer := 0;
    v_totp   integer;
    v_nomes  text;
    v_ent    boolean := (p_dados ->> 'modo') = 'Entrega';
    v_padrao numeric := COALESCE((SELECT valor::numeric FROM carniel_config WHERE chave = 'taxa_entrega'), 0);
    v_taxa   numeric := 0;
    v_combinar boolean := false;
    v_talh   integer := 0;
    v_ptalh  numeric := 1.00;
    v_bairro text;
    v_rua    text;
    v_num_end text;
    v_end    text;
    v_pag    text;
    v_troco  numeric;
    v_num    integer;
    v_id     integer;
    v_total  numeric;
    v_linhas text[] := '{}';
    v_obsg   text[] := '{}';
    v_esc    text;
    v_prodnome text;
    v_texto  text;
    v_nome   text;
BEGIN
    SELECT * INTO s FROM app_sessao_carniel(p_token) x WHERE x.r_ok;
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, NULL::integer, NULL::integer, 'sessao_invalida'::text, NULL::text, NULL::text; RETURN;
    END IF;

    -- pedido repetido (mesma chave): devolve o que já foi gravado, sem criar outro
    IF v_chave IS NOT NULL THEN
        SELECT a.pedido_id INTO v_exist FROM carniel_app_pedidos a WHERE a.chave = v_chave;
        IF FOUND THEN
            RETURN QUERY SELECT true, (SELECT numero_preparo FROM carniel_pedidos WHERE id = v_exist), v_exist, 'ja_registrado'::text, NULL::text, s.r_tel;
            RETURN;
        END IF;
    END IF;

    -- horário (só o número de teste do Elton pode fora do horário)
    v_teste := right(s.r_tel, 8) = '00000000';
    v_abre  := COALESCE((SELECT valor FROM carniel_config WHERE chave = 'horario_abre'), '00:00')::time;
    v_fecha := COALESCE((SELECT valor FROM carniel_config WHERE chave = 'horario_fecha'), '23:59')::time;
    IF NOT v_teste AND (v_agora < v_abre OR v_agora >= v_fecha
                        OR NOT dia_aberto_carniel(v_hoje)) THEN
        RETURN QUERY SELECT false, NULL::integer, NULL::integer, 'fechado'::text, NULL::text, s.r_tel; RETURN;
    END IF;

    -- limite de pedidos por cliente (anti-abuso)
    IF (SELECT count(*) FROM carniel_pedidos p WHERE p.cliente_id = s.r_cliente_id AND p.origem = 'APP' AND p.data_pedido > now() - interval '1 hour') >= 6 THEN
        RETURN QUERY SELECT false, NULL::integer, NULL::integer, 'muitos_pedidos'::text, NULL::text, s.r_tel; RETURN;
    END IF;

    IF jsonb_typeof(p_dados -> 'itens') <> 'array' OR jsonb_array_length(p_dados -> 'itens') = 0 THEN
        RETURN QUERY SELECT false, NULL::integer, NULL::integer, 'carrinho_vazio'::text, NULL::text, s.r_tel; RETURN;
    END IF;
    IF jsonb_array_length(p_dados -> 'itens') > 40 THEN
        RETURN QUERY SELECT false, NULL::integer, NULL::integer, 'itens_demais'::text, NULL::text, s.r_tel; RETURN;
    END IF;

    SELECT count(*) INTO v_totp FROM jsonb_array_elements(p_dados -> 'itens') x WHERE x ->> 'k' = 'pers';

    FOR it IN SELECT * FROM jsonb_array_elements(p_dados -> 'itens') LOOP
        v_k   := it ->> 'k';
        v_qtd := least(greatest(COALESCE(nullif(it ->> 'qtd', '')::integer, 1), 1), 50);
        v_obs := nullif(left(btrim(COALESCE(it ->> 'obs', '')), 300), '');

        IF v_k = 'oferta' THEN
            SELECT c.id AS cid, c.nome AS cnome INTO r
              FROM carniel_dias d JOIN carniel_dia_config c ON c.dia_id = d.id AND c.ativo
             WHERE d.data_dia = v_hoje AND d.ativo AND c.tipo LIKE 'MARMITA%' AND c.nome = (it ->> 'nome') LIMIT 1;
            IF NOT FOUND THEN
                RETURN QUERY SELECT false, NULL::integer, NULL::integer, ('indisponivel: ' || COALESCE(it ->> 'nome', '?'))::text, NULL::text, s.r_tel; RETURN;
            END IF;
            SELECT x.preco INTO v_preco FROM preco_grupo_carniel(r.cnome) x;
            IF v_preco IS NULL THEN
                RETURN QUERY SELECT false, NULL::integer, NULL::integer, ('sem_preco: ' || r.cnome)::text, NULL::text, s.r_tel; RETURN;
            END IF;
            v_itens := v_itens || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'grupo', 'Marmitas', 'produto', r.cnome, 'config_id', r.cid, 'nome_base', r.cnome, 'grupo_tipo', 'MARMITA',
                'preco_unit', v_preco, 'quantidade', v_qtd, 'tipo_venda', 'UNIDADE', 'observacao', v_obs)));
            v_sub := v_sub + v_preco * v_qtd;
            v_linhas := v_linhas || format('%sx %s%s', v_qtd, r.cnome, CASE WHEN v_obs IS NOT NULL THEN ' (' || v_obs || ')' ELSE '' END);

        ELSIF v_k = 'tam' THEN
            SELECT pr.id AS pid, pr.nome AS pnome, pr.preco AS ppreco INTO r
              FROM carniel_precos pr
             WHERE pr.ativo AND pr.categoria IN ('TAMANHO', 'TAMANHO_FEIJAO') AND pr.chave = (it ->> 'chave') LIMIT 1;
            IF NOT FOUND OR r.ppreco IS NULL THEN
                RETURN QUERY SELECT false, NULL::integer, NULL::integer, ('indisponivel: ' || COALESCE(it ->> 'chave', '?'))::text, NULL::text, s.r_tel; RETURN;
            END IF;
            v_itens := v_itens || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'grupo', 'Marmita por tamanho', 'produto', r.pnome, 'config_id', -1, 'grupo_tipo', 'OFERTA',
                'preco_unit', r.ppreco, 'produto_id', -r.pid, 'quantidade', v_qtd, 'tipo_venda', 'UNIDADE', 'observacao', v_obs)));
            v_sub := v_sub + r.ppreco * v_qtd;
            v_linhas := v_linhas || format('%sx %s%s', v_qtd, r.pnome, CASE WHEN v_obs IS NOT NULL THEN ' (' || v_obs || ')' ELSE '' END);

        ELSIF v_k = 'prod' THEN
            SELECT p.id AS pid, p.nome AS pnome, p.preco AS ppreco, c.id AS cid, c.tipo AS ctipo, c.nome AS cnome INTO r
              FROM carniel_produtos p
              JOIN carniel_dia_config_itens i ON i.produto_id = p.id AND i.ativo
              JOIN carniel_dia_config c ON c.id = i.config_id AND c.ativo
              JOIN carniel_dias d ON d.id = c.dia_id AND d.data_dia = v_hoje AND d.ativo
             WHERE p.ativo AND p.id = (it ->> 'id')::integer
               AND c.tipo IN ('BEBIDAS', 'PIZZA_CRUA_OU_ASSADA', 'SALADAS', 'TAPIOCAS') LIMIT 1;
            IF NOT FOUND THEN
                RETURN QUERY SELECT false, NULL::integer, NULL::integer, ('indisponivel: produto ' || COALESCE(it ->> 'id', '?'))::text, NULL::text, s.r_tel; RETURN;
            END IF;
            IF r.ctipo = 'BEBIDAS' THEN
                v_preco := r.ppreco;
            ELSE
                SELECT x.preco INTO v_preco FROM preco_grupo_carniel(r.cnome) x;
            END IF;
            IF v_preco IS NULL THEN
                RETURN QUERY SELECT false, NULL::integer, NULL::integer, ('sem_preco: ' || r.pnome)::text, NULL::text, s.r_tel; RETURN;
            END IF;
            v_prodnome := r.pnome;
            IF r.ctipo = 'PIZZA_CRUA_OU_ASSADA' THEN
                v_esc := initcap(COALESCE(it ->> 'esc', ''));
                IF v_esc NOT IN ('Crua', 'Assada') THEN
                    RETURN QUERY SELECT false, NULL::integer, NULL::integer, 'pizza_crua_ou_assada'::text, NULL::text, s.r_tel; RETURN;
                END IF;
                v_prodnome := 'Pizza de ' || r.pnome || ' (' || lower(v_esc) || ')';
            END IF;
            v_itens := v_itens || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'grupo', r.cnome, 'produto', v_prodnome, 'config_id', r.cid, 'grupo_tipo', r.ctipo,
                'preco_unit', v_preco, 'produto_id', r.pid, 'quantidade', v_qtd, 'tipo_venda', 'UNIDADE', 'observacao', v_obs)));
            v_sub := v_sub + v_preco * v_qtd;
            v_linhas := v_linhas || format('%sx %s%s', v_qtd, v_prodnome, CASE WHEN v_obs IS NOT NULL THEN ' (' || v_obs || ')' ELSE '' END);

        ELSIF v_k = 'pers' THEN
            v_np := v_np + 1;
            v_pend := true;
            v_nomes := NULL;
            IF jsonb_typeof(it -> 'marcados') <> 'array' OR jsonb_array_length(it -> 'marcados') = 0 THEN
                RETURN QUERY SELECT false, NULL::integer, NULL::integer, 'personalizada_vazia'::text, NULL::text, s.r_tel; RETURN;
            END IF;
            FOR v_mid IN SELECT jsonb_array_elements_text(it -> 'marcados') LOOP
                SELECT p.id AS pid, p.nome AS pnome, c.id AS cid INTO r
                  FROM carniel_produtos p
                  JOIN carniel_dia_config_itens i ON i.produto_id = p.id AND i.ativo
                  JOIN carniel_dia_config c ON c.id = i.config_id AND c.ativo
                  JOIN carniel_dias d ON d.id = c.dia_id AND d.data_dia = v_hoje AND d.ativo
                 WHERE p.ativo AND p.id = v_mid::integer AND c.tipo IN ('CARDAPIO', 'CARNES') LIMIT 1;
                IF NOT FOUND THEN
                    RETURN QUERY SELECT false, NULL::integer, NULL::integer, ('indisponivel: buffet ' || v_mid)::text, NULL::text, s.r_tel; RETURN;
                END IF;
                v_itens := v_itens || jsonb_build_array(jsonb_build_object(
                    'grupo', CASE WHEN v_totp > 1 THEN 'Personalizada ' || v_np ELSE 'Personalizada' END,
                    'produto', r.pnome, 'config_id', r.cid, 'grupo_tipo', 'CARDAPIO', 'produto_id', r.pid,
                    'quantidade', 1, 'tipo_venda', 'KG'));
                v_nomes := COALESCE(v_nomes || ', ', '') || r.pnome;
            END LOOP;
            v_linhas := v_linhas || format('1x %s: %s%s — valor na pesagem',
                                           CASE WHEN v_totp > 1 THEN 'Personalizada ' || v_np ELSE 'Personalizada' END,
                                           v_nomes, CASE WHEN v_obs IS NOT NULL THEN ' (' || v_obs || ')' ELSE '' END);
            IF v_obs IS NOT NULL THEN
                v_obsg := v_obsg || format('%s: %s', CASE WHEN v_totp > 1 THEN 'Personalizada ' || v_np ELSE 'Personalizada' END, v_obs);
            END IF;
        ELSE
            RETURN QUERY SELECT false, NULL::integer, NULL::integer, 'item_invalido'::text, NULL::text, s.r_tel; RETURN;
        END IF;
    END LOOP;

    -- entrega / taxa / endereço
    IF v_ent THEN
        v_rua     := btrim(COALESCE(p_dados #>> '{end,rua}', ''));
        v_num_end := btrim(COALESCE(p_dados #>> '{end,num}', ''));
        v_bairro  := btrim(COALESCE(p_dados #>> '{end,bairro}', ''));
        IF v_rua = '' OR v_num_end = '' THEN
            RETURN QUERY SELECT false, NULL::integer, NULL::integer, 'endereco_incompleto'::text, NULL::text, s.r_tel; RETURN;
        END IF;
        -- bairro 'A combinar' = endereço novo / cidade vizinha: taxa fica 0 e a equipe define depois ("frete 5 8")
        v_combinar := lower(v_bairro) = 'a combinar';
        IF v_combinar THEN
            v_taxa := 0;
        ELSE
            SELECT t.taxa INTO v_taxa FROM carniel_taxas_locais t WHERE t.ativo AND lower(t.nome) = lower(v_bairro) LIMIT 1;
            IF v_taxa IS NULL THEN v_taxa := v_padrao; END IF;
        END IF;
        v_end := left(v_rua || ', ' || v_num_end
                 || CASE WHEN nullif(btrim(COALESCE(p_dados #>> '{end,comp}', '')), '') IS NOT NULL THEN ' - ' || btrim(p_dados #>> '{end,comp}') ELSE '' END
                 || CASE WHEN v_bairro <> '' AND lower(v_bairro) <> 'na cidade' AND NOT v_combinar THEN ' - ' || v_bairro ELSE '' END, 300);
    END IF;

    -- pagamento
    v_pag := CASE p_dados ->> 'pag'
                 WHEN 'Pix' THEN 'PIX' WHEN 'Cartão' THEN 'CARTAO' WHEN 'Dinheiro' THEN 'DINHEIRO'
                 WHEN 'Convênio' THEN CASE WHEN s.r_convenio THEN 'CONVENIO' ELSE NULL END
                 ELSE NULL END;
    IF v_pag IS NULL THEN
        RETURN QUERY SELECT false, NULL::integer, NULL::integer, 'pagamento_invalido'::text, NULL::text, s.r_tel; RETURN;
    END IF;
    BEGIN
        v_troco := nullif(replace(regexp_replace(COALESCE(p_dados ->> 'troco', ''), '[^0-9,.]', '', 'g'), ',', '.'), '')::numeric;
    EXCEPTION WHEN OTHERS THEN v_troco := NULL;
    END;
    IF v_pag <> 'DINHEIRO' THEN v_troco := NULL; END IF;

    -- talheres (site): 0 a 20, cobrados por unidade (carniel_config.preco_talher, padrão 1,00).
    -- Entram como item do pedido (sai na comanda e no Meus pedidos) e somam no total.
    BEGIN
        v_talh := least(greatest(COALESCE(nullif(p_dados ->> 'talheres', '')::numeric, 0), 0), 20)::integer;
    EXCEPTION WHEN OTHERS THEN v_talh := 0;
    END;
    IF v_talh > 0 THEN
        SELECT COALESCE((SELECT replace(valor, ',', '.')::numeric FROM carniel_config WHERE chave = 'preco_talher'), 1.00) INTO v_ptalh;
        v_itens := v_itens || jsonb_build_array(jsonb_build_object(
            'grupo', 'Pedido', 'produto', 'Talheres', 'grupo_tipo', 'ADMIN', 'sem_qtd', false,
            'preco_unit', v_ptalh, 'quantidade', v_talh, 'tipo_venda', 'UNIDADE'));
        v_sub := v_sub + v_ptalh * v_talh;
        v_linhas := v_linhas || format('%sx Talheres', v_talh);
    END IF;

    v_total := v_sub + CASE WHEN v_ent THEN v_taxa ELSE 0 END;

    -- número do dia (mesmo contador do bot) e gravação
    INSERT INTO carniel_contador_preparo (dia, ultimo) VALUES (v_hoje, 1)
    ON CONFLICT (dia) DO UPDATE SET ultimo = carniel_contador_preparo.ultimo + 1
    RETURNING ultimo INTO v_num;

    INSERT INTO carniel_pedidos (cliente_id, itens_pedido, valor_total, taxa_entrega, status, status_impressao,
                                 tentativas_impressao, data_finalizacao, numero_preparo, observacao,
                                 forma_pagamento, origem, tipo_entrega, endereco_entrega, troco_para, taxa_a_combinar)
    VALUES (s.r_cliente_id, v_itens, v_total, CASE WHEN v_ent THEN v_taxa ELSE 0 END, 'FINALIZADO', 'PENDENTE',
            0, now(), v_num, nullif(array_to_string(v_obsg, E'\n'), ''),
            v_pag, 'APP', CASE WHEN v_ent THEN 'ENTREGA' ELSE 'RETIRADA' END,
            v_end || CASE WHEN v_combinar THEN ' - ⚠ FRETE A COMBINAR' ELSE '' END, v_troco, v_combinar)
    RETURNING id INTO v_id;

    INSERT INTO carniel_app_pedidos (chave, pedido_id, cliente_id) VALUES (COALESCE(v_chave, 'sem-chave-' || v_id), v_id, s.r_cliente_id);

    v_nome := nullif(left(btrim(COALESCE(p_dados ->> 'nome', '')), 100), '');
    UPDATE carniel_clientes c
       SET data_ultimo_pedido = now(),
           nome = COALESCE(c.nome, v_nome),
           endereco_texto = CASE WHEN v_ent AND c.endereco_texto IS NULL THEN v_end ELSE c.endereco_texto END
     WHERE c.id = s.r_cliente_id;

    -- texto da cópia que o n8n manda no WhatsApp do cliente
    v_texto := 'Pedido #' || v_num || E'\n' || array_to_string(v_linhas, E'\n') || E'\n'
        || CASE WHEN v_ent THEN 'Entrega: ' || v_end ELSE 'Retirada no restaurante' END || E'\n'
        || 'Pagamento: ' || initcap(lower(CASE v_pag WHEN 'CARTAO' THEN 'Cartão' WHEN 'CONVENIO' THEN 'Convênio' ELSE v_pag END))
        || CASE WHEN v_troco IS NOT NULL THEN ' (troco para R$ ' || replace(to_char(v_troco, 'FM999990.00'), '.', ',') || ')' ELSE '' END || E'\n'
        || 'Itens: R$ ' || replace(to_char(v_sub, 'FM999990.00'), '.', ',') || E'\n'
        || CASE WHEN v_ent AND v_combinar THEN 'Taxa de entrega: a combinar' || E'\n'
                WHEN v_ent THEN 'Taxa de entrega: R$ ' || replace(to_char(v_taxa, 'FM999990.00'), '.', ',') || E'\n' ELSE '' END
        || 'Total: R$ ' || replace(to_char(v_total, 'FM999990.00'), '.', ',') || CASE WHEN v_pend THEN ' + Personalizada(s) a pesar' ELSE '' END
        || CASE WHEN v_combinar THEN ' + frete a combinar' ELSE '' END
        || E'\n\n🔒 Este pedido já está salvo no sistema. Editar esta mensagem não altera nada. Para mudar, fale com a gente.';

    RETURN QUERY SELECT true, v_num, v_id, NULL::text, v_texto, s.r_tel;
END
$f$;
