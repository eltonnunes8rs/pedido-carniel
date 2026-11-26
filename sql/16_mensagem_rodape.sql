-- 16: mensagem do cardápio com saudação completa + rodapé da equipe.
-- Mantém a função atual como "corpo" e a nova mensagem_cardapio_dia_carniel apenas completa o texto.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname='mensagem_cardapio_corpo_carniel') THEN
    ALTER FUNCTION mensagem_cardapio_dia_carniel(date) RENAME TO mensagem_cardapio_corpo_carniel;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.mensagem_cardapio_dia_carniel(p_data date)
 RETURNS text LANGUAGE sql AS $f$
  SELECT replace(mensagem_cardapio_corpo_carniel(p_data), 'Bom diaaaaa! ☀️', 'Bom diaaaaa! ☀️😃❤️')
         || E'\n\n⏳ Preparo por ordem de pedido. Tempo médio: 45 a 55 minutos.'
         || E'\n\n❤️ Agradecemos a sua preferência! Que seu dia seja lindo e abençoado! 😃❤️';
$f$;
