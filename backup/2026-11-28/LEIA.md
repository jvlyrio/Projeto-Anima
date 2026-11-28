# Backup de 28/11/2026 — Partes 1 a 4, Fila Casual e pendências do servidor

- `z-arena.html`: o jogo com tudo desta rodada. **Não publicado no site** (o site segue no commit 9cc79c8).
- `site/zsb.js` e `site/zsb.css`: login do site só com Google (sem convidado). Entram no site junto com a postagem.
- `servidor/`: o que mudou no banco, na ordem em que foi aplicado:
  1. `d1_termos_no_servidor.sql`: termos conferidos no servidor (chaves `termos_versao` e `termos_exigir`).
  2. `d2_fila_casual.sql`: tabela e funções da Fila Casual.
  3. `d3_salas_chave_jogador.sql`: o carimbo do modo servidor passa a reconhecer os jogadores dentro das salas.
  4. `d4_somente_google.sql`: conta de convidado não joga nem grava nada. As 84 contas de convidado foram apagadas
     (os dados delas estão guardados no schema `backup_20261128_convidados` do Supabase).
  5. `d5_salas_sorteio_e_draft.sql`: o servidor sorteia quem começa, quem bane primeiro e o desempate do campo,
     e confere o draft no começo da batalha (chave `salas_sorteio`).
  6. `d6_rk_bot_no_servidor.sql`: ranqueada contra bot aberta pelo servidor, com o MMR do bot decidido lá.
- `perfil_originais/`: as bandeiras e molduras enviadas em 28/11 (Aurora, Gelo, Lua Roxa, Magma, Maré, Natal e Violeta), no tamanho original.
  O jogo usa versões reduzidas e medidas (bandeira 512×768, moldura 384×384 com o buraco no centro).
- `midia/`: os 6 vídeos novos de ultimate (Sakura, Turles e Goku Black SSJ Rose, japonês e dublado), já com o nome
  que o site usa em `media/`. Copiar para `media/` antes do build se não estiverem lá.
- `servidor/LIGAR_NA_POSTAGEM.sql`: o que rodar no dia da postagem (liga `prog_estrito`, `termos_exigir` e `salas_sorteio`).
  Hoje as três estão desligadas.
- O estado do banco ANTES destas mudanças está no schema `backup_20261127` do próprio Supabase.
- Sem dados de jogadores neste backup.
