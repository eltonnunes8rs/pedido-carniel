-- 1) MANUAL (usado pelo "ajuda <pergunta>") — 3 assuntos novos
INSERT INTO carniel_manual (ordem, perfil, assunto, texto) VALUES
(270, 'ADMIN', 'Modo SITE / LIVRE (pedido pelo WhatsApp)',
E'\n"site" liga o modo SITE: o robô manda o link do site (1 vez por dia por cliente) e, se o cliente continuar pedindo pelo WhatsApp, fica quieto, pausa por 1 hora e avisa o grupo para a equipe fazer o pedido.\n"livre" volta ao normal (o robô monta o pedido pelo WhatsApp). "robo" mostra os dois modos (quem o robô atende e se o pedido está em SITE ou LIVRE).\nO SITE só vale para quem o robô atende: deixe "robo todos" para valer para todos os clientes.\nSe o cliente quiser falar por aqui, a resposta depende da atendente.\n'),
(280, 'EQUIPE', 'Pedido feito pelo site (app)',
E'\nO cliente pode pedir em pedido.restaurantecarniel.com.br: entra com o celular (recebe um código de 6 dígitos no WhatsApp), escolhe o que quer e envia. O pedido cai como qualquer outro (número da comanda, impressão na cozinha) e o cliente recebe uma cópia no WhatsApp avisando que editar essa mensagem não muda nada.\nSó aceita pedido de hoje e com o restaurante aberto. Taxa, preço e itens do dia são conferidos pelo sistema.\nPersonalizada vem por peso: o cliente marca os itens do buffet de hoje; depois de pesar, use "valor 3 48,50" como sempre. Duas Personalizadas viram "Personalizada 1" e "Personalizada 2" na comanda.\nSe o cardápio do site não abrir, o cliente vê um botão para chamar o restaurante pelo WhatsApp.\n'),
(290, 'ADMIN', 'Quantos clientes já usam o site',
E'\nO sistema guarda quando cada cliente validou o código pela primeira vez, o último acesso e quantos pedidos fez pelo site. Para ver o total é uma consulta no banco (view carniel_app_clientes_v). Pedidos do site aparecem com origem APP.\n');

-- 2) AJUDA ("comandos") — acrescenta o bloco do site / livre e do pedido pelo site; mantém o bloco de taxas
CREATE OR REPLACE FUNCTION public.texto_ajuda_carniel()
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
-- VERSÃO 22/11/2026 (bloco "Pedido pelo site": site / livre) — antes: 18/11/2026 (Passo 267: bloco "Taxa de entrega por local")
SELECT replace(
    texto_ajuda_carniel_base(),
    E'*Só administrador — regras do cliente (IA)*',
    E'*Pedido pelo site*\n'
    || E'• *site* — o robô manda o link do site e, se o cliente insistir em pedir, fica quieto e avisa o grupo\n'
    || E'• *livre* — o robô volta a montar o pedido pelo WhatsApp\n'
    || E'• *robo* — mostra quem o robô atende e se o pedido está em SITE ou LIVRE\n'
    || E'   _pedidos feitos no site saem na cozinha como os outros (origem APP)_\n\n'
    || E'*Taxa de entrega por local*\n'
    || E'• *taxas* — lista os locais com taxa e a taxa padrão\n'
    || E'• *taxa fazenda caldato 4* — cadastra (ou troca) a taxa do local\n'
    || E'• *tira taxa fazenda caldato* — apaga o local (volta a taxa padrão)\n'
    || E'   _o bot procura o nome do local no endereço que o cliente escreve_\n\n'
    || E'*Só administrador — regras do cliente (IA)*'
);
$function$;

-- 3) CLIENTES QUE JÁ USARAM O SITE (sem mexer no cadastro nem nas funções que funcionam)
CREATE OR REPLACE VIEW carniel_app_clientes_v AS
SELECT c.id AS cliente_id,
       c.nome,
       c.telefone_whatsapp,
       min(s.criado_em) AS primeiro_acesso,
       max(s.ultimo_uso) AS ultimo_acesso,
       (SELECT count(*) FROM carniel_app_pedidos ap WHERE ap.cliente_id = c.id) AS pedidos_pelo_site
FROM carniel_app_sessoes s
JOIN carniel_clientes c ON c.id = s.cliente_id
GROUP BY c.id, c.nome, c.telefone_whatsapp;

-- Consultas úteis:
-- SELECT count(*) AS clientes_que_validaram FROM carniel_app_clientes_v;
-- SELECT (primeiro_acesso AT TIME ZONE 'America/Sao_Paulo')::date dia, count(*) FROM carniel_app_clientes_v GROUP BY 1 ORDER BY 1;
-- Teste do ajuda:  SELECT texto_ajuda_carniel();
