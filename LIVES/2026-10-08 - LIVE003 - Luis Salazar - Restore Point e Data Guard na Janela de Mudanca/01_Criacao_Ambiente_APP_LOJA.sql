-- ============================================================================
--  LIVE #03 | ARQUIVO 01 de 04 | CRIACAO DO AMBIENTE DA APLICACAO APP_LOJA
--  Executado por: DBA, na vespera (antes da live)
--  Convidado: Luis Salazar | Conducao: Roberto Sobrinho (DBA Sobrinho)
--  Data da live: quinta 08/10/2026, 19h00
-- ============================================================================
--
--  O QUE ESTE ARQUIVO FAZ
--    Cria a aplicacao LOJA versao 1.0: o "sistema em producao" que vai
--    sofrer o deploy na live. Roda so no PRIMARIO; o standby recebe tudo
--    sozinho pelo redo do Data Guard.
--
--    PODE RODAR QUANTAS VEZES QUISER: o primeiro bloco apaga a APP_LOJA
--    (se existir) e o resto recria do zero. Sempre sai igual.
--    NUNCA rodar no meio da janela da live (depois do arquivo 02).
--    No fim tira a "foto" do estado inicial, que vai ser comparada depois
--    do rollback.
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
-- ## D-1 (VESPERA): PREPARAR A APLICACAO DE EXEMPLO
-- ## Fazer ANTES da live. Isso e o "sistema em producao" que vai sofrer o deploy.
-- ############################################################################

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- Instalacao limpa: se a APP_LOJA ja existir (de um ensaio anterior), apaga
-- tudo antes de criar. Sem isso, rodar o 01 de novo da erro de objeto
-- existente ou duplica dados. Na primeira vez o bloco so avisa e segue.
-- O drop tambem vai para o standby pelo redo.

SET SERVEROUTPUT ON
DECLARE
  v_qtd NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_qtd FROM dba_users WHERE username = 'APP_LOJA';
  IF v_qtd > 0 THEN
    EXECUTE IMMEDIATE 'DROP USER app_loja CASCADE';
    DBMS_OUTPUT.PUT_LINE('APP_LOJA existia: apagada para instalar do zero.');
  ELSE
    DBMS_OUTPUT.PUT_LINE('APP_LOJA nao existia: primeira instalacao.');
  END IF;
END;
/

-- Cria o dono da aplicacao. No Data Guard tudo isso vai sozinho para o
-- standby pelo redo, nao precisa rodar nada do outro lado.

CREATE USER app_loja IDENTIFIED BY "Loja#2026"
  DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;

GRANT CREATE SESSION, CREATE TABLE, CREATE PROCEDURE, CREATE SEQUENCE TO app_loja;

-- Tabelas da versao 1.0 da aplicacao.

CREATE TABLE app_loja.produto (
  id_produto  NUMBER        PRIMARY KEY,
  nome        VARCHAR2(60)  NOT NULL,
  preco       NUMBER(10,2)  NOT NULL
);

CREATE TABLE app_loja.pedido (
  id_pedido   NUMBER        PRIMARY KEY,
  id_produto  NUMBER        REFERENCES app_loja.produto,
  quantidade  NUMBER        NOT NULL,
  status      VARCHAR2(20)  NOT NULL,
  criado_em   DATE          DEFAULT SYSDATE
);

-- Tabela de controle de versao: e nela que a gente "enxerga" o deploy.

CREATE TABLE app_loja.controle_versao (
  versao      VARCHAR2(10) PRIMARY KEY,   -- impede versao duplicada se o 01 rodar 2 vezes
  aplicado_em DATE DEFAULT SYSDATE,
  observacao  VARCHAR2(100)
);

-- Massa de dados: 10 produtos e 5.000 pedidos.

INSERT INTO app_loja.produto
SELECT level, 'PRODUTO ' || LPAD(level,2,'0'), ROUND(50 + level * 7.5, 2)
  FROM dual CONNECT BY level <= 10;

INSERT INTO app_loja.pedido (id_pedido, id_produto, quantidade, status, criado_em)
SELECT level,
       MOD(level,10) + 1,
       MOD(level,5) + 1,
       CASE MOD(level,4) WHEN 0 THEN 'ENTREGUE' WHEN 1 THEN 'PAGO'
                         WHEN 2 THEN 'ENVIADO'  ELSE 'NOVO' END,
       SYSDATE - MOD(level,30)
  FROM dual CONNECT BY level <= 5000;

INSERT INTO app_loja.controle_versao VALUES ('1.0', SYSDATE, 'Versao em producao');

COMMIT;

-- Forca uma troca de log para o standby receber tudo agora.

ALTER SYSTEM SWITCH LOGFILE;

-- ----------------------------------------------------------------------------
-- SERVIDOR: srvora4 | INSTANCIA: AUTOBR | PAPEL: PRIMARY | sqlplus / as sysdba
-- ----------------------------------------------------------------------------
-- "Foto" do sistema ANTES do deploy. Guarde esse resultado: no fim da live
-- ele tem que ser IGUAL. E a prova de que o rollback funcionou.

SET LINESIZE 200 PAGESIZE 100
SELECT versao, TO_CHAR(aplicado_em,'DD/MM/YYYY HH24:MI:SS') aplicado_em FROM app_loja.controle_versao;
SELECT status, COUNT(*) qtd FROM app_loja.pedido GROUP BY status ORDER BY status;
SELECT SUM(preco) soma_precos FROM app_loja.produto;

-- Esperado: versao 1.0 | 1.250 pedidos em cada status | soma_precos = 912,50





-- ############################################################################
-- ## EXTRA: ZERAR O LAB PARA ENSAIAR DE NOVO
-- ############################################################################
-- Nao precisa mais de bloco separado: e so rodar este arquivo de novo.
-- Ele apaga a APP_LOJA no inicio e recria tudo do zero.

-- ============================================================================
--  https://dbasobrinho.com.br
-- ============================================================================
