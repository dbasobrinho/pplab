-- ============================================================================
--  LIVE #03 | ARQUIVO 03 de 04 | DEPLOY DA APLICACAO (VERSAO 2.0)
--  Executado por: time de desenvolvimento (19:10), validacao as 19:40
--  Convidado: Luis Salazar | Conducao: Roberto Sobrinho (DBA Sobrinho)
--  Data da live: quinta 08/10/2026, 19h00
-- ============================================================================
--
--  O QUE ESTE ARQUIVO FAZ
--    E o pacote de deploy da versao 2.0, do jeito que o time de dev entregou.
--    Mistura DDL (coluna, tabela e procedure novas) com DML (reajuste de
--    preco e atualizacao de pedidos). Tem um erro plantado: um UPDATE sem
--    WHERE. Depois vem a validacao, que falha e gera a solicitacao de rollback.
--
--  PRE-REQUISITO: arquivo 02 executado (restore point nos dois lados).
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
-- ## 19:10 | >>>>>>>>>>>>>>>>>>>>>  MOMENTO DO DEPLOY  <<<<<<<<<<<<<<<<<<<<<<<
-- ## Aqui entra o pacote da versao 2.0, exatamente como o time de
-- ## desenvolvimento entregou.
-- ############################################################################

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Em producao isso rodaria conectado como APP_LOJA. Aqui uso o prefixo do
-- schema para rodar tudo da mesma sessao sysdba.

-- Passo 1 do deploy: DDL, coluna nova em PRODUTO.
ALTER TABLE app_loja.produto ADD (preco_promocional NUMBER(10,2));

-- Passo 2 do deploy: DDL, tabela nova de cupons.
CREATE TABLE app_loja.cupom (
  codigo      VARCHAR2(20) PRIMARY KEY,
  desconto    NUMBER(5,2),
  valido_ate  DATE
);

INSERT INTO app_loja.cupom VALUES ('LIVE03', 10, SYSDATE + 30);

-- Passo 3 do deploy: DML, reajuste de 10% nos precos.
UPDATE app_loja.produto SET preco = ROUND(preco * 1.10, 2);

-- Passo 4 do deploy: DML, "fechar pedidos antigos".
-- O desenvolvedor esqueceu o WHERE. Era para cancelar so pedido NOVO com
-- mais de 20 dias. Vai cancelar TODOS os 5.000 pedidos.
UPDATE app_loja.pedido SET status = 'CANCELADO';

-- Passo 5 do deploy: DDL, procedure nova.
CREATE OR REPLACE PROCEDURE app_loja.aplica_cupom (p_codigo VARCHAR2) AS
BEGIN
  UPDATE app_loja.produto p
     SET p.preco_promocional = ROUND(p.preco * (1 - (SELECT c.desconto FROM app_loja.cupom c
                                                      WHERE c.codigo = p_codigo) / 100), 2);
END;
/

-- Passo 6 do deploy: registra a versao nova.
INSERT INTO app_loja.controle_versao VALUES ('2.0', SYSDATE, 'Deploy da janela');

COMMIT;

-- Troca o log para o standby receber e APLICAR o deploy inteiro.
-- Isso e importante para a historia: o erro tambem chegou no DR.
ALTER SYSTEM SWITCH LOGFILE;

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora3 | INSTANCIA: AUTOUS | PAPEL: STANDBY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Por que mostrar isso: o Data Guard protege contra perder o servidor,
-- NAO contra erro logico. O UPDATE sem WHERE ja esta aplicado no standby.
-- Fazer switchover ou failover agora nao resolveria nada.

SET LINESIZE 200 PAGESIZE 100
COL name  FORMAT A15
COL value FORMAT A20
SELECT process, status, sequence# FROM v$managed_standby WHERE process = 'MRP0';
SELECT name, value FROM v$dataguard_stats WHERE name IN ('transport lag','apply lag');



-- ############################################################################
-- ## 19:40 | SOLICITACAO DE ROLLBACK: VALIDACAO FALHOU
-- ############################################################################

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- A validacao funcional da aplicacao roda e encontra o estrago.

SET LINESIZE 200 PAGESIZE 100
SELECT versao, TO_CHAR(aplicado_em,'DD/MM/YYYY HH24:MI:SS') aplicado_em FROM app_loja.controle_versao;
SELECT status, COUNT(*) qtd FROM app_loja.pedido GROUP BY status ORDER BY status;
SELECT SUM(preco) soma_precos FROM app_loja.produto;

-- Resultado: 5.000 pedidos CANCELADOS e precos ja reajustados.
--
-- Por que nao consertar "na mao":
--   - Nao existe backup do status antigo de cada pedido.
--   - Tem DDL no meio (coluna, tabela, procedure). FLASHBACK TABLE nao desfaz.
--   - Cada minuto tentando consertar e minuto de loja fora do ar.
-- Decisao do responsavel pela mudanca: VOLTAR PARA O RESTORE POINT.

-- Guardar o SCN atual antes de voltar (vai para o relatorio da janela).
SELECT current_scn FROM v$database;



-- ----------------------------------------------------------------------------
-- SOLICITACAO DE ROLLBACK ABERTA
-- ----------------------------------------------------------------------------
-- O responsavel pela mudanca pede a volta. O DBA segue com o arquivo 04.

-- ============================================================================
--  https://dbasobrinho.com.br
-- ============================================================================
