# Backup de 28/11/2026 — Teste e correção das Partes 1 a 4 + Fila Casual

- `z-arena.html`: o jogo depois dos testes e correções (é o mesmo do link de teste, versão 598). **Não publicado no site.**
- `servidor/`: o que mudou no banco nesta rodada, na ordem em que foi aplicado:
  1. `d1_termos_no_servidor.sql` — termos conferidos no servidor (chaves `termos_versao` e `termos_exigir`, esta desligada até a postagem).
  2. `d2_fila_casual.sql` — tabela e funções da Fila Casual.
  3. `d3_salas_chave_jogador.sql` — o carimbo do modo servidor passa a reconhecer os jogadores dentro das salas.
- O backup do estado do banco ANTES destas mudanças está no schema `backup_20261127` do próprio Supabase.
- Sem dados de jogadores neste backup.
