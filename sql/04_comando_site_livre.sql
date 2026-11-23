-- Comandos "site" e "livre" (e "robo site" / "robo livre") pelo caminho que o comando "robo" já usa.
-- Só troca a função robo_comando_carniel (mantém TODOS / VIP / NENHUM exatamente como estava).
-- Antes de rodar, garanta o interruptor:
INSERT INTO carniel_config (chave, valor, descricao)
VALUES ('bot_pedido_modo', 'LIVRE', 'LIVRE = bot monta pedido. SITE = manda o link do site 1x por dia e, se o cliente insistir em pedir, pausa para a equipe.')
ON CONFLICT (chave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.robo_comando_carniel(p_tel text, p_modo text DEFAULT ''::text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
-- VERSÃO 22/11/2026 (modo SITE/LIVRE do pedido pelo WhatsApp) — antes: 03/11/2026 (Passo 150; última mudança: Passo 137)
DECLARE
    v_modo  text := upper(COALESCE(p_modo, ''));
    v_valor text;
    v_admin boolean;
    v_vips  integer;
    v_site  text;
BEGIN
    SELECT EXISTS (SELECT 1 FROM carniel_usuarios u
                   WHERE u.ativo AND u.perfil = 'ADMIN'
                     AND chave_telefone_carniel(u.telefone_whatsapp) = chave_telefone_carniel(p_tel))
      INTO v_admin;

    -- NOVO: site | livre
    IF v_modo IN ('SITE', 'LIVRE') THEN
        IF NOT v_admin THEN
            RETURN '🔒 Só o *administrador* muda o modo do robô.';
        END IF;
        UPDATE carniel_config SET valor = v_modo, data_atualizacao = now() WHERE chave = 'bot_pedido_modo';
        IF NOT FOUND THEN
            INSERT INTO carniel_config (chave, valor) VALUES ('bot_pedido_modo', v_modo);
        END IF;
        RETURN CASE v_modo
            WHEN 'SITE' THEN '🌐 *Modo SITE ligado.* O robô manda o link do site 1x por dia e, se o cliente insistir em pedir pelo WhatsApp, fica quieto e avisa o grupo para a equipe fazer o pedido.' || E'\n' || '_Para voltar: *livre*_'
            ELSE '✅ *Modo LIVRE.* O robô volta a montar pedidos pelo WhatsApp como sempre.' || E'\n' || '_Para mandar os clientes ao site: *site*_'
        END;
    END IF;

    IF v_modo IN ('TODOS', 'VIP', 'NENHUM') THEN
        IF NOT v_admin THEN
            RETURN '🔒 Só o *administrador* muda o modo do robô.';
        END IF;
        v_valor := CASE v_modo WHEN 'VIP' THEN 'LISTA' ELSE v_modo END;
        UPDATE carniel_config SET valor = v_valor WHERE chave = 'bot_modo';
        IF NOT FOUND THEN
            INSERT INTO carniel_config (chave, valor) VALUES ('bot_modo', v_valor);
        END IF;
    END IF;

    SELECT COALESCE((SELECT valor FROM carniel_config WHERE chave = 'bot_modo' LIMIT 1), 'LISTA') INTO v_valor;
    SELECT COUNT(*)::integer INTO v_vips FROM carniel_bot_liberados WHERE ativo;
    SELECT COALESCE((SELECT upper(btrim(valor)) FROM carniel_config WHERE chave = 'bot_pedido_modo' LIMIT 1), 'LIVRE') INTO v_site;

    RETURN CASE
        WHEN v_valor = 'TODOS'  THEN '🤖 *Robô: TODOS* — atende qualquer cliente.' || E'\n' || '_Para voltar só aos VIP: *robo vip*_'
        WHEN v_valor = 'NENHUM' THEN '🤖 *Robô: NENHUM* — não atende nenhum cliente, tudo manual. Os comandos da equipe continuam funcionando.' || E'\n' || '_Para ligar: *robo vip* ou *robo todos*_'
        ELSE '🤖 *Robô: só VIP* — atende só os ' || v_vips || ' cliente(s) da lista (*vips*). Os outros ficam com vocês.' || E'\n' || '_Para abrir: *robo todos* · para desligar: *robo nenhum*_'
    END
    || E'\n' || CASE WHEN v_site = 'SITE'
                     THEN '🌐 Pedido pelo WhatsApp: *SITE* (manda o link). Para voltar: *livre*'
                     ELSE '💬 Pedido pelo WhatsApp: *LIVRE*. Para mandar ao site: *site*' END;
END;
$function$;

-- teste (troque pelo seu telefone de ADMIN, só números):
-- SELECT robo_comando_carniel('5546999999999', '');
