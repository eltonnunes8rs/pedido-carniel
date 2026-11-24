-- 11 — Relatório diário (14h): acrescenta o bloco "📱 App de pedidos"
-- Seguro para rodar mais de uma vez. Não mexe nos números que já existem no relatório.
-- Desfazer: DROP FUNCTION relatorio_dia_carniel(date); ALTER FUNCTION relatorio_dia_base_carniel(date) RENAME TO relatorio_dia_carniel;

-- 1) a função atual vira "base" (só na primeira vez)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'relatorio_dia_base_carniel') THEN
    ALTER FUNCTION public.relatorio_dia_carniel(date) RENAME TO relatorio_dia_base_carniel;
  END IF;
END $$;

-- 2) números do app em um dia
CREATE OR REPLACE FUNCTION public.app_dia_dados_carniel(p_data date)
RETURNS jsonb
LANGUAGE sql
AS $f$
  SELECT jsonb_build_object(
    'pedidos_app',  (SELECT count(*) FROM carniel_pedidos p
                      WHERE p.origem = 'APP' AND p.status <> 'CANCELADO'
                        AND (p.data_pedido AT TIME ZONE 'America/Sao_Paulo')::date = p_data),
    'clientes_app', (SELECT count(DISTINCT p.cliente_id) FROM carniel_pedidos p
                      WHERE p.origem = 'APP' AND p.status <> 'CANCELADO'
                        AND (p.data_pedido AT TIME ZONE 'America/Sao_Paulo')::date = p_data),
    'pedidos_total',(SELECT count(*) FROM carniel_pedidos p
                      WHERE p.status <> 'CANCELADO'
                        AND (p.data_pedido AT TIME ZONE 'America/Sao_Paulo')::date = p_data),
    'abriram',      (SELECT count(DISTINCT e.sessao_dev) FROM carniel_app_eventos e
                      WHERE e.evento = 'abriu'
                        AND (e.criado_em AT TIME ZONE 'America/Sao_Paulo')::date = p_data),
    'carrinho',     (SELECT count(DISTINCT e.sessao_dev) FROM carniel_app_eventos e
                      WHERE e.evento = 'item_add'
                        AND (e.criado_em AT TIME ZONE 'America/Sao_Paulo')::date = p_data),
    'instalaram',   (SELECT count(DISTINCT e.sessao_dev) FROM carniel_app_eventos e
                      WHERE e.evento = 'app_instalado'
                        AND (e.criado_em AT TIME ZONE 'America/Sao_Paulo')::date = p_data)
  );
$f$;

-- 3) o relatório: texto de sempre + bloco do app no fim
CREATE OR REPLACE FUNCTION public.relatorio_dia_carniel(p_data date DEFAULT CURRENT_DATE)
RETURNS TABLE(destino text, texto text)
LANGUAGE plpgsql
AS $f$
DECLARE
  r     record;
  v_ant date;
  h     jsonb;
  o     jsonb;
  t     text;
BEGIN
  SELECT * INTO r FROM relatorio_dia_base_carniel(p_data);

  SELECT max((l.criado_em)::date) INTO v_ant
  FROM carniel_conversa_log l
  WHERE l.criado_em < p_data AND l.direcao = 'CLIENTE';

  h := app_dia_dados_carniel(p_data);
  o := CASE WHEN v_ant IS NULL THEN NULL ELSE app_dia_dados_carniel(v_ant) END;

  t := E'\n\n📱 *App de pedidos*'
    || E'\n• Pedidos pelo app: *' || (h->>'pedidos_app') || '* de ' || (h->>'pedidos_total')
       || CASE WHEN (h->>'pedidos_total')::int > 0
               THEN ' = ' || round(100.0 * (h->>'pedidos_app')::int / (h->>'pedidos_total')::int)::text || '%' ELSE '' END
       || CASE WHEN o IS NOT NULL
               THEN ' (' || to_char(v_ant, 'DD/MM') || ': ' || (o->>'pedidos_app') || ' de ' || (o->>'pedidos_total') || ')' ELSE '' END
    || E'\n• Clientes que pediram pelo app: *' || (h->>'clientes_app') || '*'
       || CASE WHEN o IS NOT NULL THEN ' (' || (o->>'clientes_app') || ')' ELSE '' END
    || E'\n• Aparelhos que abriram: *' || (h->>'abriram') || '* · com item no carrinho: ' || (h->>'carrinho')
       || ' · instalaram: ' || (h->>'instalaram')
       || CASE WHEN o IS NOT NULL THEN ' (abriram ' || (o->>'abriram') || ')' ELSE '' END;

  destino := r.destino;
  texto   := r.texto || t;
  RETURN NEXT;
END;
$f$;

-- teste (só lê): deve mostrar o relatório com o bloco 📱 no fim
SELECT texto FROM relatorio_dia_carniel(CURRENT_DATE);
