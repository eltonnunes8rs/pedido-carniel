-- 15 — Telefone no começo do app (reconhece convênio sem pedir código) — 25/11/2026
-- Cria app_telefone_carniel(p_tel, p_dev). Não altera nada existente.
-- Desfazer: DROP FUNCTION app_telefone_carniel(text, text);
CREATE OR REPLACE FUNCTION app_telefone_carniel(p_tel text, p_dev text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_tel text := app_tel_limpo_carniel(p_tel);
  v_t8 text;
  v_conv boolean;
BEGIN
  IF v_tel IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'telefone_invalido');
  END IF;
  -- trava contra consulta em massa: máx. 20 consultas/hora por aparelho e 300/hora no total
  IF (SELECT count(*) FROM carniel_app_eventos
       WHERE evento = 'consulta_tel' AND sessao_dev = left(COALESCE(p_dev,'?'),64)
         AND criado_em > now() - interval '1 hour') >= 20
     OR (SELECT count(*) FROM carniel_app_eventos
          WHERE evento = 'consulta_tel' AND criado_em > now() - interval '1 hour') >= 300 THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'muitas_consultas');
  END IF;
  INSERT INTO carniel_app_eventos (sessao_dev, evento, dados)
  VALUES (left(COALESCE(p_dev,'?'),64), 'consulta_tel', '{}'::jsonb);

  v_t8 := right(v_tel, 8);
  SELECT COALESCE(bool_or(cl.convenio), false) INTO v_conv
    FROM carniel_clientes cl
   WHERE right(regexp_replace(COALESCE(cl.telefone_whatsapp,''), '\D', '', 'g'), 8) = v_t8;
  -- devolve só se é convênio; nunca nome nem outro dado do cliente
  RETURN jsonb_build_object('ok', true, 'convenio', COALESCE(v_conv, false));
END $$;
-- Teste: SELECT app_telefone_carniel('(46) 98409-0805', 'teste');
