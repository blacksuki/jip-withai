CREATE OR REPLACE PACKAGE PKG_ZEI_CERT_CALC AS
  ----------------------------------------------------------------------------
  -- パッケージ仕様部 : PKG_ZEI_CERT_CALC
  -- 概要 : 固定資産税 証明書発行における 課税標準額・税額・件数 の算出
  ----------------------------------------------------------------------------

  -- 証明書発行のエントリポイント（単票）
  PROCEDURE p_issue_certificate(
    i_year       IN  NUMBER,
    i_chohyo_kbn IN  VARCHAR2,
    i_uketsuke   IN  VARCHAR2,
    o_kazei_disp OUT VARCHAR2,
    o_zei_disp   OUT VARCHAR2,
    o_kensu_disp OUT VARCHAR2,
    o_result     OUT VARCHAR2
  );

  -- 証明書1件分の 課税標準額・税額・件数 を計算
  PROCEDURE p_calc_shomeisho(
    i_year        IN  NUMBER,
    i_chohyo_kbn  IN  VARCHAR2,
    o_kensu_total OUT PLS_INTEGER,
    o_kazei_total OUT NUMBER,
    o_zei_total   OUT NUMBER,
    o_status      OUT VARCHAR2
  );

  -- バッチ一括発行
  PROCEDURE p_batch_issue(i_year IN NUMBER);

  -- 保守用: 単票デバッグ
  PROCEDURE p_debug_one(i_year IN NUMBER, i_chohyo_kbn IN VARCHAR2);

  -- 整合性チェック
  PROCEDURE p_self_check(o_ng_cnt OUT PLS_INTEGER);

END PKG_ZEI_CERT_CALC;
/
