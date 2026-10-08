-- ============================================================================
--  LIVE #03 | ARQUIVO 02 de 04 | PROCEDIMENTO DO DBA ANTES DO DEPLOY
--  Executado por: DBA, no inicio da janela (19:00 a 19:07)
--  Convidado: Luis Salazar | Conducao: Roberto Sobrinho (DBA Sobrinho)
--  Data da live: quinta 08/10/2026, 19h00
-- ============================================================================
--
--  O QUE ESTE ARQUIVO FAZ
--    Prepara a rota de volta ANTES de qualquer mudanca:
--    pre-check nos dois lados e restore point garantido, primeiro no
--    STANDBY e depois no PRIMARIO.
--
--  POR QUE RESTORE POINT E NAO UM "SCRIPT DE ROLLBACK"?
--    - Script de rollback desfaz o que o desenvolvedor lembrou de desfazer.
--      Deploy com DDL e DML misturados quase nunca tem volta perfeita.
--    - FLASHBACK TABLE e FLASHBACK QUERY dependem do UNDO e nao desfazem DDL.
--    - Restore de backup leva horas e perde o standby.
--    - O restore point garantido volta o BANCO INTEIRO para um SCN exato,
--      em minutos, e o Data Guard consegue seguir junto.
--    - O preco: tudo que entrou no banco depois do ponto e perdido.
--      Por isso a aplicacao fica parada durante a janela.
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
-- ## 19:00 | INICIO DA JANELA: PRE-CHECK NOS DOIS LADOS
-- ## Antes de criar qualquer ponto de retorno, confirmar que o ambiente
-- ## esta saudavel. Nao se comeca janela com Data Guard atrasado.
-- ############################################################################

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- SERVIDOR: srvora3 | INSTANCIA: AUTOUS | PAPEL: STANDBY | sqlplus / as sysdba
-- (rodar o mesmo bloco nos dois)
-- ----------------------------------------------------------------------------
-- NESTA LIVE O FLASHBACK ESTA DESLIGADO NOS DOIS LADOS (FLASHBACK_ON = NO).
-- E de proposito: muito ambiente de producao e assim, e o restore point
-- garantido funciona mesmo sem flashback ligado. O Oracle passa a gerar
-- flashback log so a partir do ponto, e o FLASHBACK_ON vira
-- "RESTORE POINT ONLY". O preco: so da para voltar EXATAMENTE para o ponto.
--
-- O QUE MUDA NO STANDBY CONFORME O FLASHBACK (testado no lab em 07/10/2026):
--
--   +---------------------------+------------------+--------------+------------------+
--   | Standby                   | Volta automatica | Volta manual | Sem volta        |
--   |                           | (MRP do 19c)     | (DBA)        |                  |
--   +---------------------------+------------------+--------------+------------------+
--   | Flashback ON + ponto      | SIM              | SIM          |                  |
--   | Flashback ON, sem ponto   | se a FRA nao     | se a FRA nao | se a FRA apagou  |
--   |                           | apagou os logs   | apagou       | os logs          |
--   | Flashback OFF + ponto     | NAO (ORA-19909)  | SIM, so para |                  |
--   |   (CENARIO DESTA LIVE)    |                  | o ponto      |                  |
--   | Flashback OFF, sem ponto  | NAO              | NAO          | recriar standby  |
--   +---------------------------+------------------+--------------+------------------+
--
-- E a FRA precisa ter espaco, porque o ponto garantido nunca deixa apagar
-- os logs de flashback gerados depois dele.
--
-- ----------------------------------------------------------------------------
-- LICENCIAMENTO (confirmar sempre no "Database Licensing Information User
-- Manual" da versao, porque a Oracle muda as regras)
-- ----------------------------------------------------------------------------
--   Flashback Database e restore point GARANTIDO
--     Enterprise Edition: incluido, SEM custo extra (nao e option).
--     Standard Edition 2: NAO tem. Sem Flashback Database, nao existe
--     restore point garantido. Em SE2 a volta de um deploy e restore.
--
--   Outros "flashbacks", para nao confundir:
--     Flashback Query (AS OF)            todas as edicoes
--     Flashback Table / Drop (lixeira)   so Enterprise Edition
--     Flashback Transaction Query        so Enterprise Edition
--     Flashback Data Archive (Time Travel) todas as edicoes desde 11.2.0.4
--       (com compressao exige Advanced Compression, que e paga)
--
--   Data Guard
--     Physical standby MONTADO (como neste lab): incluido no Enterprise
--     Edition, sem custo extra. O standby tem que ser licenciado igual ao
--     primario (mesma edicao, mesmo numero de processadores).
--     Abrir o standby READ ONLY com o apply rodando (Real-Time Query),
--     DML Redirection, Far Sync: Active Data Guard, que E OPTION PAGA.
--
--   Cuidado: o DBA_FEATURE_USAGE_STATISTICS registra o uso de cada recurso,
--   e e isso que a auditoria da Oracle olha. Neste lab ele mostra
--   "Active Data Guard - Real-Time Query" como usado (sobrou de outra live).
--   Em producao sem a option, isso vira conversa com o comercial da Oracle.

-- ----------------------------------------------------------------------------
-- VERSOES (conferido na documentacao oficial: Oracle Data Guard Concepts and
-- Administration 19c "Changes in This Release" e 12.1 "Data Guard Scenarios")
-- ----------------------------------------------------------------------------
--   12c E 19c OU MAIOR (o roteiro desta live roda igual nos dois):
--     restore point garantido, flashback do primario, ponto garantido no
--     standby com flashback manual (FLASHBACK STANDBY DATABASE TO SCN) e o
--     MRP seguindo a linha nova quando o standby esta ATRAS do resetlogs.
--   SO NO 19c OU MAIOR:
--     "Automatic Flashback of a Mounted Standby After a Primary RESETLOGS
--     Operation": o MRP volta o standby sozinho (precisa de flashback log).
--     "Replicating Restore Points from Primary to Standby": o _PRIMARY. A doc
--     diz que o ponto replicado e sempre NORMAL, mesmo se o do primario for
--     garantido.
--   No 12c, depois do resetlogs, o MRP para com ORA-19909 e a volta do
--   standby e sempre manual.

-- ----------------------------------------------------------------------------
-- VALIDACAO: EDICAO DO BANCO E FLASHBACK
-- ----------------------------------------------------------------------------
-- Por que: antes de prometer "volta por restore point" no plano de mudanca,
-- o DBA confirma que o banco e Enterprise Edition e como o flashback esta.

SET LINESIZE 200 PAGESIZE 100
COL banner_full FORMAT A80
SELECT banner_full FROM v$version;

-- Esperado: "Enterprise Edition". Se aparecer "Standard Edition 2", PARE:
-- nao existe restore point garantido, e o plano de volta tem que ser outro.

COL db_unique_name FORMAT A14
COL database_role  FORMAT A18
COL open_mode      FORMAT A20
COL flashback_on   FORMAT A20
SELECT db_unique_name, database_role, open_mode, flashback_on, current_scn
  FROM v$database;

-- Como ler o FLASHBACK_ON:
--   YES                 flashback ligado: volta para qualquer SCN dentro da
--                       retencao, e o standby do 19c volta sozinho
--   NO                  desligado: so funciona com restore point garantido
--   RESTORE POINT ONLY  desligado, mas existe ponto garantido: o Oracle
--                       gera flashback log so para voltar ate o ponto
--
-- Retencao e area de recuperacao (so pesam com FLASHBACK_ON = YES):
COL name  FORMAT A32
COL value FORMAT A20
SELECT name, value FROM v$parameter
 WHERE name IN ('db_flashback_retention_target','db_recovery_file_dest','db_recovery_file_dest_size');

-- Uso registrado dos recursos (o que a auditoria de licenca enxerga).
-- So no PRIMARIO: no standby MONTADO as views DBA_ nao abrem (ORA-01219).
COL name FORMAT A55
SELECT name, currently_used, detected_usages
  FROM dba_feature_usage_statistics
 WHERE LOWER(name) LIKE '%flashback%' OR LOWER(name) LIKE '%data guard%'
 ORDER BY name;

SELECT ROUND(space_limit/1024/1024/1024,1)          limite_gb,
       ROUND(space_used /1024/1024/1024,1)          usado_gb,
       ROUND(space_used*100/space_limit)            pct_uso
  FROM v$recovery_file_dest;

-- Nao pode existir restore point esquecido de outra janela.
COL name FORMAT A20
SELECT name, guarantee_flashback_database garantido, scn FROM v$restore_point;

-- Esperado nos dois: FLASHBACK_ON = NO | FRA com folga | nenhum restore point.

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora3 | INSTANCIA: AUTOUS | PAPEL: STANDBY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Por que: o standby precisa estar em dia. Se ele estiver atrasado, o ponto
-- dele ficaria la atras e a historia da live nao fecha.

COL name  FORMAT A15
COL value FORMAT A20
SELECT name, value FROM v$dataguard_stats WHERE name IN ('transport lag','apply lag');

SELECT process, status, sequence# FROM v$managed_standby WHERE process = 'MRP0';

-- Esperado: lag +00 00:00:00 e MRP0 em APPLYING_LOG.

-- ----------------------------------------------------------------------------
-- VERSAO DA APLICACAO ANTES DO DEPLOY
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Por que: o DBA registra a versao e o estado da APP_LOJA ANTES de qualquer
-- mudanca. E a evidencia de "como estava". Depois da volta, o mesmo script
-- roda de novo (arquivo 04) e o resultado tem que ser IDENTICO.
-- Dica: deixe esta saida visivel num terminal ate o fim da janela.

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

-- Esperado: versao 1.0 | 3 tabelas (CONTROLE_VERSAO, PEDIDO, PRODUTO) e
-- nenhuma procedure | 1.250 pedidos em cada status | soma_precos = 912,50

-- ----------------------------------------------------------------------------
-- AVISO AO NEGOCIO (fala da live)
-- ----------------------------------------------------------------------------
-- A aplicacao e parada aqui. Ninguem grava no banco durante a janela.
-- Motivo: se precisar voltar, TUDO que entrou depois do ponto some,
-- inclusive pedido de cliente de verdade.



-- ############################################################################
-- ## 19:05 | PONTO DE RETORNO NO STANDBY (PRIMEIRO, DE PROPOSITO)
-- ############################################################################

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora3 | INSTANCIA: AUTOUS | PAPEL: STANDBY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Por que o standby vem PRIMEIRO:
--   O ponto do standby precisa ficar num SCN MENOR que o do primario.
--   Depois do flashback, o primario abre com RESETLOGS e cria uma linha do
--   tempo nova a partir do SCN dele. O standby so consegue "pegar" essa
--   linha nova se ele conseguir voltar para ANTES desse SCN.
--
-- Por que parar o apply:
--   Com o MRP parado, o SCN do standby fica congelado. O ponto nasce num
--   lugar conhecido e a gente controla a ordem dos SCNs.
--
-- Por que o ponto no standby e OBRIGATORIO nesta live:
--   Com o flashback desligado, sem esse ponto o standby nao tem como voltar.
--   A unica saida seria recriar o standby.

ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

CREATE RESTORE POINT rp_antes_janela_standby GUARANTEE FLASHBACK DATABASE;

-- No 19c o real time apply ja e o padrao. O "USING CURRENT LOGFILE" e
-- deprecated e so gera warning no alert.
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;

-- Confere: o ponto existe, e garantido, e o apply voltou.
COL name         FORMAT A22
COL flashback_on FORMAT A20
SELECT flashback_on FROM v$database;

SELECT name, scn, guarantee_flashback_database garantido,
       TO_CHAR(time,'DD/MM/YYYY HH24:MI:SS') criado_em
  FROM v$restore_point;

SELECT process, status, sequence# FROM v$managed_standby WHERE process = 'MRP0';

-- Esperado: FLASHBACK_ON = RESTORE POINT ONLY (era NO antes do ponto)
--           RP_ANTES_JANELA_STANDBY garantido = YES | MRP0 APPLYING_LOG



-- ############################################################################
-- ## 19:07 | PONTO DE RETORNO NO PRIMARIO
-- ############################################################################

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Por que: este e o ponto para onde o banco de producao vai voltar.
-- O mesmo nome nos dois lados deixa o procedimento simples e sem confusao.
-- O banco continua aberto: criar restore point nao para nada.

-- Por que o primario NAO leva sufixo: o 19c replica o ponto para o standby
-- acrescentando _PRIMARY. Com o nome rp_antes_janela, a replica chega como
-- RP_ANTES_JANELA_PRIMARY, que deixa claro de onde veio.
CREATE RESTORE POINT rp_antes_janela GUARANTEE FLASHBACK DATABASE;

COL name         FORMAT A22
COL flashback_on FORMAT A20
SELECT flashback_on FROM v$database;

SELECT name, scn, guarantee_flashback_database garantido,
       TO_CHAR(time,'DD/MM/YYYY HH24:MI:SS') criado_em
  FROM v$restore_point;

-- Esperado: FLASHBACK_ON = RESTORE POINT ONLY | RP_ANTES_JANELA garantido = YES

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora3 | INSTANCIA: AUTOUS | PAPEL: STANDBY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- NOVIDADE DO 19c: o ponto criado no primario aparece SOZINHO no standby,
-- com o sufixo _PRIMARY. Mas olhe a coluna GARANTIDO: ele e NORMAL, nao
-- garantido. Ele marca PARA ONDE voltar, mas nao segura flashback log.
-- Quem garante que DA para voltar e o RP_ANTES_JANELA_STANDBY criado no standby.

COL name FORMAT A22
SELECT name, scn, guarantee_flashback_database garantido, replicated replicado
  FROM v$restore_point ORDER BY scn;

-- Esperado (ensaio do lab):
--   RP_ANTES_JANELA_STANDBY  SCN menor   GARANTIDO YES   REPLICADO NO
--   RP_ANTES_JANELA_PRIMARY  SCN maior   GARANTIDO NO    REPLICADO YES
--
-- Fala da live: compare os dois SCNs na tela.
-- O SCN do STANDBY tem que ser MENOR que o do PRIMARIO.
-- A partir daqui, os dois lados tem para onde voltar.



-- ----------------------------------------------------------------------------
-- LIBERADO PARA O DEPLOY
-- ----------------------------------------------------------------------------
-- Os dois pontos de retorno existem. O DBA avisa o time de desenvolvimento
-- que pode seguir com o arquivo 03.

-- ============================================================================
--  https://dbasobrinho.com.br
-- ============================================================================
