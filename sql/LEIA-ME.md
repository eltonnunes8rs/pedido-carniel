# SQL do app de pedidos Carniel

Rodar na ordem, no PostgreSQL do projeto. Todos usam `CREATE OR REPLACE` / `IF NOT EXISTS` e não apagam dados.

| Arquivo | O que faz |
|---|---|
| 01_login_e_pedido.sql | Login por código no WhatsApp, sessão por token e criação do pedido |
| 02_eventos_pedidos_enderecos.sql | Métricas (eventos), endereços do cliente e "Meus pedidos" |
| 04_comando_site_livre.sql | Comandos `site` / `livre` do robô (modo de pedido pelo WhatsApp) |
| 05_manual_ajuda_e_clientes_app.sql | Manual, texto de ajuda e a view de clientes que já usaram o site |
| 06_testers_do_site_NAO_USADO.sql | Lista de números liberados (não foi usado em produção) |
| 07_frete_a_combinar.sql | Frete a combinar e comando `frete 5 8` |
| 09_talheres_cobrados.sql | Talheres cobrados (R$ 1,00 cada); substitui a função de pedido do 07 |
| 10_entrega_ate.sql | Entrega só até `entrega_ate`; substitui a função de pedido do 09 |

Observações
- Os arquivos 07, 09 e 10 recriam a função `app_pedido_criar_carniel`: vale sempre a **última** executada (10 inclui tudo).
- O número de teste do dono foi trocado por `00000000` nos arquivos. Troque pelos 8 últimos dígitos do seu telefone antes de rodar.
- Os nomes (`carniel_*`) são do restaurante; em outro projeto, trocar o prefixo e adaptar as regras.
- Contexto geral do app: ../docs/CONTEXTO.md
- `11_relatorio_dia_app.sql` — relatório das 14h ganha o bloco "📱 App de pedidos" (pedidos pelo app, clientes, aparelhos que abriram/instalaram).
