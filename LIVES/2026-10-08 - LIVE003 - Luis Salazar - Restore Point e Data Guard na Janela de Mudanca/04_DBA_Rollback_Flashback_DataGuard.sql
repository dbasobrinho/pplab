-- ============================================================================
--  LIVE #03 | ARQUIVO 04 de 04 | PROCEDIMENTO DE VOLTA DO DBA (ROLLBACK)
--  Executado por: DBA (19:45 a 20:25)
--  Convidado: Luis Salazar | Conducao: Roberto Sobrinho (DBA Sobrinho)
--  Data da live: quinta 08/10/2026, 19h00
-- ============================================================================
--
--  O QUE ESTE ARQUIVO FAZ
--    Volta o PRIMARIO para o restore point (flashback + resetlogs), faz o
--    STANDBY acompanhar a linha do tempo nova sem ser recriado, valida o
--    Data Guard e apaga os pontos de retorno.
--
--  PRE-REQUISITO: arquivo 03 executado e rollback solicitado.
--
--  ORDEM DOS ARQUIVOS DA LIVE
--    01_Criacao_Ambiente_APP_LOJA.sql          (vespera)  cria a aplicacao
--    02_DBA_PreCheck_Restore_Point.sql         19:00      DBA prepara a volta
--    03_Deploy_Aplicacao_v2.sql                19:10      time de dev faz o deploy
--    04_DBA_Rollback_Flashback_DataGuard.sql   19:45      DBA executa a volta
--
--  COMO USAR
--  - NAO rode o arquivo inteiro de uma vez. Copie e cole UM BLOCO por vez,
--    no servidor indicado no cabecalho de cada bloco.
--  - Tudo que comeca com "--" e explicacao. O resto e comando.
--  - Os horarios sao os mesmos da arte do fluxo
--    (04_artes/Live03_Restore_Point_DataGuard_Fluxo_Demonstracao_16x9.png).
--
--  AMBIENTE (lab PLDG, Oracle 19c, ASM, Data Guard sem Broker)
--
--    +-----------+----------------+-----------+----------------+-----------+
--    | Servidor  | IP             | Instancia | DB_UNIQUE_NAME | Papel     |
--    +-----------+----------------+-----------+----------------+-----------+
--    | srvora4   | 192.168.56.11  | AUTOBR    | AUTO_U_BR      | PRIMARY   |
--    | srvora3   | 192.168.56.10  | AUTOUS    | AUTO_U_US      | STANDBY   |
--    +-----------+----------------+-----------+----------------+-----------+
--
--    Conexao: usuario oracle no Linux, depois "sql" (atalho para
--    rlwrap sqlplus / as sysdba). O profile ja aponta o ORACLE_SID certo.
--
--  NOMES DOS PONTOS DE RETORNO
--    STANDBY : RP_ANTES_JANELA_STANDBY (criado no srvora3)
--    PRIMARIO: RP_ANTES_JANELA         (criado no srvora4)
--    No 19c ou maior o ponto do primario aparece no standby com o sufixo
--    _PRIMARY: RP_ANTES_JANELA_PRIMARY (replicado, sempre NORMAL).
-- ============================================================================


-- ############################################################################
-- ## 19:45 | >>>>>>>>>>>>>>>>  FLASHBACK + RESETLOGS NO PRIMARIO  <<<<<<<<<<<<<<<<<<<<<<<<<<
-- ############################################################################

-- ----------------------------------------------------------------------------
-- VERSAO DA APLICACAO ANTES DO ROLLBACK
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Por que: registrar o estado "quebrado" antes de voltar. E o mesmo script
-- do arquivo 02. Agora ele mostra a versao 2.0, a tabela CUPOM, a procedure
-- APLICA_CUPOM, todos os pedidos CANCELADOS e os precos reajustados.

SET LINESIZE 200 PAGESIZE 100
COL versao      FORMAT A8
COL aplicado_em FORMAT A20
COL observacao  FORMAT A30
COL object_type FORMAT A12
COL object_name FORMAT A20
SELECT versao, TO_CHAR(aplicado_em,'DD/MM/YYYY HH24:MI:SS') aplicado_em, observacao
  FROM app_loja.controle_versao ORDER BY aplicado_em;
SELECT object_type, object_name
  FROM dba_objects WHERE owner = 'APP_LOJA' AND object_type IN ('TABLE','PROCEDURE')
 ORDER BY 1, 2;
SELECT status, COUNT(*) qtd FROM app_loja.pedido GROUP BY status ORDER BY status;
SELECT SUM(preco) soma_precos FROM app_loja.produto;

-- Esperado: versoes 1.0 e 2.0 | CUPOM e APLICA_CUPOM existem |
-- 5.000 pedidos CANCELADO | soma_precos = 1003,75

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Um comando de cada vez, olhando o retorno de cada um.
--
-- Por que SHUTDOWN e STARTUP MOUNT:
--   FLASHBACK DATABASE so roda com o banco MONTADO. Nao existe flashback
--   de banco inteiro com ele aberto.

SHUTDOWN IMMEDIATE;

STARTUP MOUNT;

-- Por que este comando: volta o banco inteiro para o SCN do RP_ANTES_JANELA,
-- usando os logs de flashback que o ponto garantido segurou na FRA.
-- Em banco pequeno leva segundos. O tempo depende do volume alterado,
-- nao do tamanho do banco.

FLASHBACK DATABASE TO RESTORE POINT rp_antes_janela;

-- Por que RESETLOGS e obrigatorio:
--   O redo gerado depois do ponto (o deploy) nao pode mais ser aplicado.
--   O RESETLOGS descarta essa historia e abre uma INCARNATION nova.
--   Aqui nasce uma linha do tempo nova. E o standby ainda esta na velha.

ALTER DATABASE OPEN RESETLOGS;

-- Confere: banco aberto, incarnation nova e o SCN onde ela comecou.
-- Anote o RESETLOGS_CHANGE#: ele e usado na volta do standby.
COL database_role FORMAT A18
COL open_mode     FORMAT A20
SELECT database_role, open_mode, resetlogs_change#,
       TO_CHAR(resetlogs_time,'DD/MM/YYYY HH24:MI:SS') resetlogs_time
  FROM v$database;

SELECT incarnation#, resetlogs_change#, status FROM v$database_incarnation ORDER BY 1;

-- ----------------------------------------------------------------------------
-- VERSAO DA APLICACAO DEPOIS DA VOLTA
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Por que: e a prova do rollback. Mesmo script do arquivo 02. O resultado
-- tem que ser IDENTICO ao "antes do deploy": a versao 2.0 sumiu, a tabela
-- CUPOM e a procedure sumiram (o flashback desfez ate o DDL) e os pedidos
-- voltaram ao status original.

SET LINESIZE 200 PAGESIZE 100
COL versao      FORMAT A8
COL aplicado_em FORMAT A20
COL observacao  FORMAT A30
COL object_type FORMAT A12
COL object_name FORMAT A20
SELECT versao, TO_CHAR(aplicado_em,'DD/MM/YYYY HH24:MI:SS') aplicado_em, observacao
  FROM app_loja.controle_versao ORDER BY aplicado_em;
SELECT object_type, object_name
  FROM dba_objects WHERE owner = 'APP_LOJA' AND object_type IN ('TABLE','PROCEDURE')
 ORDER BY 1, 2;
SELECT status, COUNT(*) qtd FROM app_loja.pedido GROUP BY status ORDER BY status;
SELECT SUM(preco) soma_precos FROM app_loja.produto;

-- Esperado (igual ao arquivo 02): so a versao 1.0 | 3 tabelas e nenhuma
-- procedure | 1.250 pedidos em cada status | soma_precos = 912,50



-- ############################################################################
-- ## 19:55 | O STANDBY FICA "NO FUTURO"
-- ############################################################################

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora3 | INSTANCIA: AUTOUS | PAPEL: STANDBY | terminal Linux
-- ----------------------------------------------------------------------------
-- Por que: o standby aplicou o deploy (19:10 a 19:40). O primario acabou de
-- desfazer essa historia. O standby esta a frente de uma linha do tempo
-- que nao existe mais.
--
-- Deixar o alert aberto num terminal (atalho do profile):
--     alert
--
-- O QUE APARECE NO ALERT (ensaio real do lab, flashback OFF, 07/10/2026):
--
--   rfs: Standby in the future of new recovery destination branch(resetlogs_id)
--   rfs: Effect of primary database OPEN RESETLOGS
--   Setting recovery target incarnation to 5
--   MRP0: Incarnation has changed! Retry recovery...
--   ORA-19906: recovery target incarnation changed during recovery
--   MRP0: Detected orphaned datafiles!
--   ORA-19909: datafile 1 belongs to an orphan incarnation
--
--   ... uns 20 segundos depois, o 19c TENTA a volta automatica:
--
--   MRP0: Recovery coordinator performing automatic flashback of database
--         to SCN:0x000000000090d4bf (9491647)        <- SCN do _PRIMARY
--   ORA-38726: Flashback database logging is not on.
--   MRP0: Recovery coordinator encountered one or more errors during
--         automatic flashback on standby
--   Background Media Recovery process shutdown
--
-- Traduzindo: o RFS continua recebendo o redo da linha nova, mas o MRP
-- MORRE. Os datafiles do standby tem mudancas (o deploy) que nao existem
-- mais no primario: eles ficaram "orfaos" na incarnation velha.
-- O 19c (ou maior) ate tenta voltar sozinho para o SCN do RP_ANTES_JANELA_PRIMARY, mas
-- com FLASHBACK_ON = RESTORE POINT ONLY os flashback logs so servem para
-- voltar EXATAMENTE ao ponto garantido do standby, nao para um SCN
-- qualquer. Por isso o ORA-38726. A volta tem que ser manual.

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora3 | INSTANCIA: AUTOUS | PAPEL: STANDBY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Quem esta aplicando e em qual incarnation o standby esta.

SELECT process, status, sequence#, thread# FROM v$managed_standby WHERE process IN ('MRP0','RFS');
SELECT incarnation#, resetlogs_change#, status FROM v$database_incarnation ORDER BY 1;
SELECT current_scn FROM v$database;

-- Esperado (flashback OFF):
--   MRP0 NAO aparece (morreu com ORA-19909)
--   incarnation nova ja registrada como CURRENT (o RFS registrou)
--   CURRENT_SCN do standby MAIOR que o RESETLOGS_CHANGE# do primario
--   -> o standby esta no futuro. Seguir para o passo 20:00.



-- ############################################################################
-- ## 20:00 | STANDBY VOLTA JUNTO
-- ############################################################################

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora3 | INSTANCIA: AUTOUS | PAPEL: STANDBY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Por que funciona: o ponto do standby (19:05) tem SCN MENOR que o
-- RESETLOGS_CHANGE# do primario. Voltando para ele, o standby fica antes da
-- bifurcacao e consegue aplicar o redo da incarnation nova sem buraco.
-- Nada de recriar standby, nada de copiar 1 TB pela rede.
--
-- O CANCEL vai devolver "ORA-16136: Managed Standby Recovery not active".
-- E NORMAL: o MRP ja tinha morrido. O comando fica no roteiro para o caso
-- de ele ainda estar de pe.

ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

-- Com flashback OFF, so da para voltar para o ponto garantido, nao para
-- qualquer SCN. No lab levou menos de 1 segundo.
FLASHBACK DATABASE TO RESTORE POINT rp_antes_janela_standby;

ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;

-- No alert, o MRP volta, aplica o resto da incarnation velha ate a
-- bifurcacao e segue na nova:
--   Media Recovery start incarnation depth : 1, target inc# : 5
--   PR00: Media Recovery Log ... thread_1_seq_1 ...  (linha nova)

-- ----------------------------------------------------------------------------
-- BONUS (19c OU MAIOR): E SE O FLASHBACK ESTIVESSE LIGADO NO STANDBY?
-- ----------------------------------------------------------------------------
-- No 19c ou maior (no 12c nao existe), com o standby MONTADO, FLASHBACK_ON = YES e o MRP rodando, o
-- proprio MRP faz essa volta SOZINHO, sem DBA. Evidencia do ensaio do lab
-- (07/10/2026, flashback ON), alert do standby:
--
--   14:44:16  primario abre com RESETLOGS
--   14:44:55  MRP0: Recovery coordinator performing automatic flashback of
--             database to SCN:0x0000000000907161 (9466209)
--   14:44:56  Flashback Media Recovery Complete
--   14:44:57  Setting recovery target incarnation to 4
--             Managed Standby Recovery starting Real Time Apply
--
-- O alvo foi o SCN do RP_ANTES_JANELA_PRIMARY (o ponto replicado). Mas quem
-- garantiu que os flashback logs ainda estavam la foi o RP_ANTES_JANELA_STANDBY
-- garantido do standby, com SCN menor. Sem ele, numa janela longa com a FRA
-- apertada, o Oracle poderia ter apagado esses logs.

-- PLANO B: e se NAO existisse o ponto no standby?
-- Com flashback OFF: nao tem volta. Recriar o standby (duplicate from
-- active database ou restore a partir do primario).
-- Com flashback ON: da para voltar por SCN, desde que ainda existam logs
-- de flashback cobrindo esse horario (a retencao e 1440 min, mas e so meta).
-- Pegar no PRIMARIO: SELECT resetlogs_change# - 2 FROM v$database;
-- Conferir no STANDBY: SELECT oldest_flashback_scn FROM v$flashback_database_log;
-- E rodar no STANDBY, com o MRP parado:
--     FLASHBACK STANDBY DATABASE TO SCN <valor_do_primario>;
-- Por isso o ponto nos dois lados e o caminho seguro.
--
-- OUTRA OPCAO: "REINSTATE MANUAL" DO STANDBY
-- E a mesma tecnica do reinstate de um ex-primario depois de failover
-- (flashback ate o ponto de bifurcacao e volta a aplicar), so que sem o
-- CONVERT TO PHYSICAL STANDBY, porque aqui o banco nunca deixou de ser
-- standby. Tambem depende de flashback log cobrindo o SCN. Fica para
-- outra situacao (ver LIVE #04, Failover e Reinstate).



-- ############################################################################
-- ## 20:10 | VALIDACAO FINAL
-- ############################################################################

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Gera redo novo para provar que o transporte funciona na linha nova.

ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;

COL error FORMAT A40
SELECT dest_id, status, error FROM v$archive_dest_status WHERE dest_id = 2;

-- Esperado: dest 2 VALID e sem erro.

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora3 | INSTANCIA: AUTOUS | PAPEL: STANDBY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- O standby tem que estar na mesma incarnation do primario e com lag zerando.

SET LINESIZE 200 PAGESIZE 100
COL name  FORMAT A15
COL value FORMAT A20
SELECT incarnation#, resetlogs_change#, status FROM v$database_incarnation ORDER BY 1;
SELECT process, status, sequence# FROM v$managed_standby WHERE process = 'MRP0';
SELECT name, value FROM v$dataguard_stats WHERE name IN ('transport lag','apply lag');

-- Esperado: incarnation CURRENT igual a do primario | MRP0 APPLYING_LOG | lag zerando.
-- Aplicacao validada no primario funcionando como antes da janela (versao 1.0).



-- ############################################################################
-- ## 20:20 | LIMPEZA DOS PONTOS DE RETORNO (NAO PULAR)
-- ############################################################################

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Por que: ponto garantido esquecido segura TODOS os logs de flashback
-- gerados depois dele. A FRA enche, o archiver para e o banco congela.
-- E o tipo de incidente que acontece semanas depois da janela.

DROP RESTORE POINT rp_antes_janela;

COL flashback_on FORMAT A20
SELECT COUNT(*) pontos_restantes FROM v$restore_point;
SELECT flashback_on FROM v$database;

-- Esperado: 0 pontos | FLASHBACK_ON volta para NO.

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora3 | INSTANCIA: AUTOUS | PAPEL: STANDBY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- O RP_ANTES_JANELA_PRIMARY some sozinho: o drop do primario vai pelo redo.
-- Ja o RP_ANTES_JANELA_STANDBY foi criado aqui e precisa ser apagado aqui.

COL name FORMAT A22
SELECT name, guarantee_flashback_database garantido, replicated replicado FROM v$restore_point;

ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

DROP RESTORE POINT rp_antes_janela_standby;

ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;

COL flashback_on FORMAT A20
SELECT COUNT(*) pontos_restantes FROM v$restore_point;
SELECT flashback_on FROM v$database;
SELECT process, status, sequence# FROM v$managed_standby WHERE process = 'MRP0';

-- Esperado: 0 pontos | FLASHBACK_ON = NO | MRP0 APPLYING_LOG.



-- ############################################################################
-- ## 20:25 | FIM DA JANELA
-- ############################################################################
-- Ambiente igual ao de antes da mudanca:
--   - primario com a versao 1.0 e os dados intactos
--   - standby sincronizado na incarnation nova, sem ser recriado
--   - nenhum restore point pendurado
-- O deploy volta para o time de desenvolvimento corrigir o WHERE.




-- ============================================================================
--  https://dbasobrinho.com.br
-- ============================================================================
