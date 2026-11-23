# Contexto: app de pedidos do Restaurante Carniel (para replicar em outro projeto)

Gerado em 23/11/2026. Cole este texto no início do novo projeto para o Claude entender o que foi feito e fazer igual.

## 1. O que é
Um site/app (PWA instalável) onde o cliente de um restaurante faz o pedido sozinho, em vez de conversar com o robô no WhatsApp. Ele **não substitui** o robô: usa o mesmo banco, o mesmo número de comanda e a mesma impressão. O robô segue atendendo pelo WhatsApp e, no "modo SITE", manda o link do site.

- **Código (GitHub):** https://github.com/eltonnunes8rs/pedido-carniel (branch `main`, tudo na raiz)
- **Endereço público:** https://pedido.restaurantecarniel.com.br
- **Stack do projeto:** WhatsApp (uazapi) + n8n (Cloudfy) + Gemini + PostgreSQL. O site é só vitrine: **toda regra de negócio fica no banco (funções Postgres)** e o n8n só liga o site às funções.

## 2. Arquitetura (quem faz o quê)
```
Cliente (celular)
   │  abre https://pedido.restaurantecarniel.com.br   (GitHub Pages, arquivos estáticos)
   ▼
index.html  ──fetch──►  n8n (webhooks /webhook/app-carniel/...)  ──SQL──►  PostgreSQL (funções)
                              │
                              └─► uazapi (WhatsApp): manda o código de login e a cópia do pedido
```
- **Hospedagem do site:** GitHub Pages (grátis). Repositório com `index.html`, `manifest.webmanifest`, `sw.js`, `icon-192.png`, `icon-512.png`, `logo.png` e o arquivo `CNAME` (contém só o domínio).
- **Domínio:** subdomínio no DNS do registro do domínio, um registro `CNAME` apontando para `eltonnunes8rs.github.io`. No GitHub: Settings → Pages → Custom domain + "Enforce HTTPS". O arquivo `CNAME` no repo mantém o domínio fixo.
- **Um arquivo só:** `index.html` com HTML, CSS e JS juntos (sem framework, sem build). Fácil de publicar e de o Claude editar.
- **Endpoints n8n** (todos com `allowedOrigins` = só o domínio do site):
  - GET `cardapio` — monta o cardápio do dia, tamanhos/preços, locais de entrega com taxa, horários (`horario_abre`, `horario_fecha`, `entrega_ate`) e a hora do servidor (`agora`).
  - POST `codigo` — pede o código de login (envia 6 dígitos no WhatsApp).
  - POST `entrar` — valida o código e devolve um token de sessão.
  - POST `pedido` — cria o pedido (devolve o número da comanda).
  - POST `meus-pedidos` — histórico do cliente (30 dias).
  - POST `enderecos` — listar/salvar/apagar endereços do cliente (também devolve se o cliente é de convênio).
  - POST `evento` — métricas de uso.
- **3 workflows n8n:** leitura do cardápio; login e pedido; meus pedidos/endereços/eventos. Cada webhook → nó Postgres (`SELECT * FROM funcao($1,...)`) → nó "Responder ao webhook".

## 3. Regra de ouro
**O site nunca decide preço, taxa, horário, estoque ou limite.** Ele só mostra e envia a intenção. O servidor (função Postgres) recalcula tudo e recusa o que não vale. Assim, uma página velha ou adulterada não consegue fraudar. O site também repete algumas regras só para a tela (por exemplo esconder "Entrega" depois das 13:00), mas o banco é quem manda.

## 4. Login por código no WhatsApp (sem senha)
1. Cliente digita o telefone → `codigo`. O banco gera 6 dígitos, guarda **só o hash (md5)**, validade 10 min, e o n8n envia por WhatsApp.
2. Cliente digita o código → `entrar`. Até 3 tentativas; se certo, cria uma **sessão com token** (validade 60 dias) guardado no aparelho (`localStorage`).
3. Todas as chamadas seguintes mandam o token; o banco confere em `app_sessao_carniel(token)`.
- **Anti-abuso:** máx. 3 códigos/hora por telefone, 60/hora no total, 6 pedidos/hora por cliente, 200 eventos/hora por aparelho.
- **Cliente identificado pelos últimos 8 dígitos** do telefone (resolve o 9º dígito e o DDI/DDD).
- Cliente novo (não cadastrado) é criado no primeiro login.
- Opcional: lista de testers (`carniel_app_liberados` + `app_acesso`) para liberar só alguns números; não foi usado.

## 5. Pedido
- Itens vão como referência (`ref`: oferta, tamanho, produto), nunca com preço. O banco busca o preço.
- Personalizada (marmita por peso): entra "valor na pesagem"; a equipe define depois com o comando `valor 3 48,50`.
- **Idempotência:** o site gera uma `chave` por pedido; reenviar a mesma chave devolve o mesmo pedido (evita duplicar com clique duplo ou internet ruim). Tabela de ligação `carniel_app_pedidos(chave, pedido_id, cliente_id)`.
- Grava em `carniel_pedidos` (origem `APP`), pega o **número do dia** do mesmo contador do robô (`carniel_contador_preparo`), a impressora imprime normalmente e o cliente recebe uma **cópia por WhatsApp** avisando que editar a mensagem não altera o pedido.
- Pagamento: Pix, Cartão, Dinheiro (com troco). **Cliente de convênio** (`carniel_clientes.convenio = true`) só vê "Convênio".
- **Talheres:** R$ 1,00 cada (`carniel_config.preco_talher`), viram um item "Talheres" no pedido.
- **Taxa de entrega:** por local (`carniel_taxas_locais`); cidade usa `taxa_entrega` padrão. Opção "Outro local — frete a combinar": taxa 0, `taxa_a_combinar = true`, comanda sai com "⚠ FRETE A COMBINAR", e a equipe define depois pelo WhatsApp com `frete 5 8` (pedido 5, R$ 8).
- **Horário:** `horario_abre` / `horario_fecha`; entrega só até `entrega_ate` (13:00); depois, só retirada. Só o número de teste do dono pode pedir fora do horário.

## 6. Tabelas e funções principais (nomes reais, prefixo `carniel_`)
- Tabelas do app: `carniel_app_codigos`, `carniel_app_sessoes`, `carniel_app_pedidos`, `carniel_app_enderecos` (único por cliente+apelido), `carniel_app_eventos` (métricas).
- Tabelas do restaurante que o app só lê/escreve: `carniel_clientes`, `carniel_pedidos`, `carniel_config` (chave/valor: `bot_modo`, `bot_pedido_modo`, `horario_abre`, `horario_fecha`, `entrega_ate`, `taxa_entrega`, `preco_talher`...), `carniel_taxas_locais`, `carniel_dias`/`carniel_dia_config` (cardápio do dia).
- Funções: `app_pedir_codigo_carniel`, `app_validar_codigo_carniel`, `app_sessao_carniel`, `app_pedido_criar_carniel`, `app_meus_pedidos_carniel`, `app_enderecos_listar_carniel`, `app_endereco_salvar_carniel`, `app_endereco_apagar_carniel`, `app_evento_carniel`, `frete_comando_carniel`.
- View de adoção: `carniel_app_clientes_v` (primeiro acesso, último acesso, pedidos pelo site por cliente). `SELECT count(*) FROM carniel_app_clientes_v` = quantos clientes já usaram.
- Métricas (`carniel_app_eventos`): abriu, modo, item_add, fechar, pediu_codigo, logou, enviou, erro_pedido, nao_liberado, falha_cardapio, clicou_zap, clicou_instalar, instalar_resposta, app_instalado, link_enviado.

## 7. Integração com o robô do WhatsApp
- **Modo SITE/LIVRE** (`carniel_config.bot_pedido_modo`): em SITE, se o cliente manda algo sem cara de pedido, o robô responde 1 vez por dia com o link; se ele insistir em pedir pelo WhatsApp, o robô fica quieto e avisa a equipe. Comandos da equipe: `site`, `livre`, `robo` (mostra o estado).
- Esses comandos usam o caminho de comandos já existente (nenhum nó novo): só regex no nó que lê o comando + função SQL.

## 8. App instalável (PWA) e atualização
- `manifest.webmanifest` (nome, cores, ícones 192/512, `display: standalone`) + `sw.js` (service worker mínimo).
- O service worker guarda só a casca (página e ícones) e **sempre busca a página nova** (`cache: no-cache`); cardápio e pedido nunca vêm de cache.
- **Android/Chrome:** o evento `beforeinstallprompt` permite um botão "Instalar o app" na própria página. **iPhone/Safari:** não existe botão; a página mostra a dica "Compartilhar → Adicionar à Tela de Início".
- **Aviso de nova versão:** o `index.html` tem `var VERSAO="2026-11-23.4"`. O app confere (4 s depois de abrir e ao voltar para a frente) se a versão publicada é diferente e mostra a faixa "Nova versão — toque para atualizar". **A cada publicação, trocar a `VERSAO`**, senão o app instalado não percebe.

## 9. Como publicar uma mudança (fluxo usado)
1. `git fetch; git checkout -B <nome> origin/main`
2. Editar `index.html` (trocar `VERSAO`), conferir a sintaxe do JS.
3. Commit, `git push`, abrir PR e **squash merge** na `main` (via `gh`). O GitHub Pages publica em ~1–2 minutos.
4. Mudança de banco: o dono roda o SQL (o token do MCP do Cloudfy só lê o Postgres e edita o n8n). Cada alteração vira um arquivo `app_pedidos_NN_assunto.sql`, sempre com `CREATE OR REPLACE`/`IF NOT EXISTS`, rodando de uma vez, sem apagar nada.
5. Mudança no n8n: editar só os nós necessários e deixar um snapshot para desfazer.

## 10. Testes
- Sem acesso à rede, o site foi testado com **jsdom** e `fetch` simulado (cenários: horário, sem cardápio, login, pedido, convênio, frete a combinar, talheres, atualização de versão).
- No site: `?exemplo=1` (dados de mentira), `?falha=1` (tela de falha), `?fechado=1` (simula fechado), `?o=bot` (origem para métrica).
- Teste real obrigatório depois de publicar: fazer um pedido pelo celular e olhar a comanda impressa.

## 11. Lições (evitar erros repetidos)
- Preferir **corrigir o mínimo** e não quebrar o que funciona; mudar uma coisa de cada vez.
- Para n8n: indicar NODE + CAMPO + AÇÃO; campos de expressão nunca começam com "=".
- Não criar nós novos para comandos que já cabem no caminho existente.
- "Sem cardápio hoje" **não é erro**: mostrar mensagem de horário/cardápio indisponível, não a tela de falha.
- Token/segredos nunca no código do site; o site só conhece a URL pública dos webhooks.
- O service worker não pode servir página velha (usar `no-cache`) e a página precisa de número de versão visível.

## 12. Para adaptar a outro projeto (ex.: MARIANA / ResolvAí)
Trocar o domínio, o nome das tabelas/funções (prefixo), o conteúdo da tela (em vez de cardápio: serviços/orçamentos/agenda) e as regras de negócio (horário, preços). Manter a estrutura: **site estático no GitHub Pages + domínio por CNAME + webhooks n8n finos + regras em funções Postgres + login por código no WhatsApp + sessão por token + métricas de eventos + PWA com aviso de versão**.
