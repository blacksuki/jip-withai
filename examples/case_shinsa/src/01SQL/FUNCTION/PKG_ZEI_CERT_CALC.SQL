CREATE OR REPLACE PACKAGE BODY PKG_ZEI_CERT_CALC AS
  ----------------------------------------------------------------------------
  -- パッケージ : PKG_ZEI_CERT_CALC
  -- 概要       : 固定資産税 証明書発行における 課税標準額・税額・件数 の算出
  -- 対象帳票   : 評価証明書 / 公課証明書 / 償却資産証明書
  -- 物件区分   : 01=土地 / 02=家屋 / 03=償却資産
  -- 備考       : 本体はShift-JISで管理されているため一部コメントが文字化けする
  ----------------------------------------------------------------------------

  -- ===== パッケージ内 定数 =====
  C_KBN_TOCHI     CONSTANT VARCHAR2(2) := '01';  -- 土地
  C_KBN_KAOKU     CONSTANT VARCHAR2(2) := '02';  -- 家屋
  C_KBN_SHOKYAKU  CONSTANT VARCHAR2(2) := '03';  -- 償却資産

  C_CHOHYO_HYOKA  CONSTANT VARCHAR2(3) := '110'; -- 評価証明書
  C_CHOHYO_KOKA   CONSTANT VARCHAR2(3) := '120'; -- 公課証明書
  C_CHOHYO_SHOKYA CONSTANT VARCHAR2(3) := '130'; -- 償却資産証明書

  C_TAX_RATE      CONSTANT NUMBER      := 0.014; -- 標準税率 1.4%
  C_MEN_LIMIT_T   CONSTANT NUMBER      := 300000;-- 土地 免税点
  C_MEN_LIMIT_K   CONSTANT NUMBER      := 200000;-- 家屋 免税点
  C_MEN_LIMIT_S   CONSTANT NUMBER      := 150000;-- 償却 免税点

  -- ===== パッケージ内 型 =====
  TYPE T_KENSU_REC IS RECORD (
    bukken_kbn  VARCHAR2(2),
    kensu       PLS_INTEGER,
    hyoka_gaku  NUMBER,
    kazei_hyo   NUMBER
  );

  -- 内部ロガー
  PROCEDURE p_log(i_lvl IN VARCHAR2, i_msg IN VARCHAR2) IS
  BEGIN
    -- 本番ではT_APP_LOGへINSERT。ここでは簡略化。
    NULL;
  EXCEPTION WHEN OTHERS THEN
    NULL; -- ログ失敗は握りつぶす
  END p_log;

  ----------------------------------------------------------------------------
  -- 汎用: 対象テーブル物理名の解決
  ----------------------------------------------------------------------------
  FUNCTION func_resolve_tbl(i_year IN NUMBER, i_kbn IN VARCHAR2)
    RETURN VARCHAR2 IS
    v_tbl VARCHAR2(60);
  BEGIN
    -- 年度別・区分別の実テーブルを返す
    IF i_kbn = C_KBN_TOCHI THEN
      v_tbl := 'FIX_TOCHI_' || TO_CHAR(i_year);
    ELSIF i_kbn = C_KBN_KAOKU THEN
      v_tbl := 'FIX_KAOKU_' || TO_CHAR(i_year);
    ELSIF i_kbn = C_KBN_SHOKYAKU THEN
      v_tbl := 'FIX_SHOKYAKU_' || TO_CHAR(i_year);
    ELSE
      v_tbl := NULL;
    END IF;
    RETURN v_tbl;
  END func_resolve_tbl;

  ----------------------------------------------------------------------------
  -- 件数取得SQL生成: 土地
  --   連名帳を考慮し 大字・小字・地番 で名寄せした上で件数をCOUNT
  ----------------------------------------------------------------------------
  FUNCTION func_sql_cre_02_tochi(i_tbl IN VARCHAR2, o_sql OUT VARCHAR2)
    RETURN PLS_INTEGER IS
    v_rtn PLS_INTEGER := 0;
  BEGIN
    o_sql := 'SELECT COUNT(*) FROM ('
          || '  SELECT OOAZA_MEISHO, KOAZA_MEISHO, CHIBAN '
          || '  FROM '  || i_tbl
          || '  WHERE BUKKEN_KBN = ''' || C_KBN_TOCHI || ''''
          || '  GROUP BY OOAZA_MEISHO, KOAZA_MEISHO, CHIBAN '
          || ')';
    RETURN v_rtn;
  EXCEPTION WHEN OTHERS THEN
    v_rtn := -1;
    p_log('E', 'func_sql_cre_02_tochi: ' || SQLERRM);
    RETURN v_rtn;
  END func_sql_cre_02_tochi;

  ----------------------------------------------------------------------------
  -- 件数取得SQL生成: 家屋
  --   家屋番号単位でCOUNT
  ----------------------------------------------------------------------------
  FUNCTION func_sql_cre_03_kaoku(i_tbl IN VARCHAR2, o_sql OUT VARCHAR2)
    RETURN PLS_INTEGER IS
    v_rtn PLS_INTEGER := 0;
  BEGIN
    o_sql := 'SELECT COUNT(*) FROM ' || i_tbl
          || ' WHERE BUKKEN_KBN = ''' || C_KBN_KAOKU || '''';
    RETURN v_rtn;
  EXCEPTION WHEN OTHERS THEN
    v_rtn := -1;
    p_log('E', 'func_sql_cre_03_kaoku: ' || SQLERRM);
    RETURN v_rtn;
  END func_sql_cre_03_kaoku;

  ----------------------------------------------------------------------------
  -- ※ 旧仕様（コメントアウト）: かつては土地・家屋を1関数で処理していた
  --   FUNCTION func_sql_cre_old(...) ... 廃止
  ----------------------------------------------------------------------------

  ----------------------------------------------------------------------------
  -- 評価額の取得SQL生成 (物件区分ごと)
  ----------------------------------------------------------------------------
  FUNCTION func_sql_hyoka(i_tbl IN VARCHAR2, i_kbn IN VARCHAR2, o_sql OUT VARCHAR2)
    RETURN PLS_INTEGER IS
    v_rtn PLS_INTEGER := 0;
  BEGIN
    IF i_kbn = C_KBN_TOCHI THEN
      o_sql := 'SELECT NVL(SUM(HYOKA_GAKU),0) FROM ' || i_tbl
            || ' WHERE BUKKEN_KBN = ''' || C_KBN_TOCHI || '''';
    ELSIF i_kbn = C_KBN_KAOKU THEN
      o_sql := 'SELECT NVL(SUM(HYOKA_GAKU),0) FROM ' || i_tbl
            || ' WHERE BUKKEN_KBN = ''' || C_KBN_KAOKU || '''';
    ELSIF i_kbn = C_KBN_SHOKYAKU THEN
      -- 償却資産は取得価額ベースの評価額
      o_sql := 'SELECT NVL(SUM(HYOKA_GAKU),0) FROM ' || i_tbl
            || ' WHERE BUKKEN_KBN = ''' || C_KBN_SHOKYAKU || '''';
    ELSE
      o_sql := NULL;
      v_rtn := -1;
    END IF;
    RETURN v_rtn;
  END func_sql_hyoka;

  ----------------------------------------------------------------------------
  -- 件数取得のディスパッチャ
  --   物件区分に応じて件数取得SQLを生成し、動的SQLで件数を返す。
  ----------------------------------------------------------------------------
  FUNCTION func_get_kensu(i_year IN NUMBER, i_kbn IN VARCHAR2)
    RETURN PLS_INTEGER IS
    v_tbl   VARCHAR2(60);
    v_sql   VARCHAR2(4000);
    v_kensu PLS_INTEGER := 0;
    v_ret   PLS_INTEGER;
  BEGIN
    v_tbl := func_resolve_tbl(i_year, i_kbn);
    IF v_tbl IS NULL THEN
      p_log('W', 'func_get_kensu: unknown kbn=' || i_kbn);
      RETURN 0;
    END IF;

    -- ★ 物件区分ごとに件数取得SQLを選択
    IF i_kbn = C_KBN_TOCHI THEN
      v_ret := func_sql_cre_02_tochi(v_tbl, v_sql);
    ELSIF i_kbn = C_KBN_KAOKU THEN
      v_ret := func_sql_cre_03_kaoku(v_tbl, v_sql);
    END IF;
    -- ※ 上記以外（償却資産=03）のとき v_sql はNULLのまま

    IF v_sql IS NULL THEN
      -- 件数SQLが生成されなかった → 0件として返す
      p_log('W', 'func_get_kensu: no count-sql for kbn=' || i_kbn);
      RETURN 0;
    END IF;

    EXECUTE IMMEDIATE v_sql INTO v_kensu;
    RETURN NVL(v_kensu, 0);
  EXCEPTION
    WHEN OTHERS THEN
      p_log('E', 'func_get_kensu: ' || SQLERRM || ' / kbn=' || i_kbn);
      RETURN 0;
  END func_get_kensu;

  ----------------------------------------------------------------------------
  -- 評価額合計の取得
  ----------------------------------------------------------------------------
  FUNCTION func_get_hyoka(i_year IN NUMBER, i_kbn IN VARCHAR2)
    RETURN NUMBER IS
    v_tbl VARCHAR2(60);
    v_sql VARCHAR2(4000);
    v_val NUMBER := 0;
    v_ret PLS_INTEGER;
  BEGIN
    v_tbl := func_resolve_tbl(i_year, i_kbn);
    IF v_tbl IS NULL THEN
      RETURN 0;
    END IF;
    v_ret := func_sql_hyoka(v_tbl, i_kbn, v_sql);
    IF v_sql IS NULL THEN
      RETURN 0;
    END IF;
    EXECUTE IMMEDIATE v_sql INTO v_val;
    RETURN NVL(v_val, 0);
  EXCEPTION WHEN OTHERS THEN
    p_log('E', 'func_get_hyoka: ' || SQLERRM);
    RETURN 0;
  END func_get_hyoka;

  ----------------------------------------------------------------------------
  -- 免税点判定
  ----------------------------------------------------------------------------
  FUNCTION func_is_menzei(i_kbn IN VARCHAR2, i_kazei_hyo IN NUMBER)
    RETURN BOOLEAN IS
  BEGIN
    IF i_kbn = C_KBN_TOCHI THEN
      RETURN (i_kazei_hyo < C_MEN_LIMIT_T);
    ELSIF i_kbn = C_KBN_KAOKU THEN
      RETURN (i_kazei_hyo < C_MEN_LIMIT_K);
    ELSIF i_kbn = C_KBN_SHOKYAKU THEN
      RETURN (i_kazei_hyo < C_MEN_LIMIT_S);
    ELSE
      RETURN TRUE;
    END IF;
  END func_is_menzei;

  ----------------------------------------------------------------------------
  -- 課税標準額の算出
  --   評価額に負担調整・特例等を適用（本サンプルでは簡略化）
  ----------------------------------------------------------------------------
  FUNCTION func_calc_kazei_hyojun(i_kbn IN VARCHAR2, i_hyoka IN NUMBER)
    RETURN NUMBER IS
    v_kazei NUMBER := 0;
  BEGIN
    IF i_hyoka IS NULL OR i_hyoka = 0 THEN
      RETURN 0;
    END IF;
    IF i_kbn = C_KBN_TOCHI THEN
      -- 住宅用地特例（1/6等）を想定した簡略計算
      v_kazei := ROUND(i_hyoka * 0.7, 0);
    ELSIF i_kbn = C_KBN_KAOKU THEN
      v_kazei := ROUND(i_hyoka * 1.0, 0);
    ELSIF i_kbn = C_KBN_SHOKYAKU THEN
      -- 償却資産は評価額＝課税標準額（原則）
      v_kazei := ROUND(i_hyoka * 1.0, 0);
    ELSE
      v_kazei := 0;
    END IF;
    RETURN v_kazei;
  END func_calc_kazei_hyojun;

  ----------------------------------------------------------------------------
  -- 税額の算出
  ----------------------------------------------------------------------------
  FUNCTION func_calc_zeigaku(i_kbn IN VARCHAR2, i_kazei_hyo IN NUMBER, i_kensu IN PLS_INTEGER)
    RETURN NUMBER IS
    v_zei NUMBER := 0;
  BEGIN
    -- 件数が0の場合は課税対象なしとして0円
    IF NVL(i_kensu,0) = 0 THEN
      RETURN 0;
    END IF;
    IF func_is_menzei(i_kbn, i_kazei_hyo) THEN
      RETURN 0; -- 免税点未満
    END IF;
    v_zei := ROUND(i_kazei_hyo * C_TAX_RATE, 0);
    RETURN v_zei;
  END func_calc_zeigaku;

  ----------------------------------------------------------------------------
  -- 帳票種別 → 物件区分リストの決定
  --   評価証明書/公課証明書は 土地・家屋・償却 を対象としうるが、
  --   本実装では 土地・家屋 のみを対象としている（後述の不具合に関連）。
  ----------------------------------------------------------------------------
  PROCEDURE p_get_target_kbn_list(
    i_chohyo_kbn IN  VARCHAR2,
    o_kbn_list   OUT SYS.ODCIVARCHAR2LIST
  ) IS
  BEGIN
    o_kbn_list := SYS.ODCIVARCHAR2LIST();
    IF i_chohyo_kbn = C_CHOHYO_HYOKA THEN
      -- 評価証明書: 土地・家屋
      o_kbn_list.EXTEND; o_kbn_list(o_kbn_list.LAST) := C_KBN_TOCHI;
      o_kbn_list.EXTEND; o_kbn_list(o_kbn_list.LAST) := C_KBN_KAOKU;
    ELSIF i_chohyo_kbn = C_CHOHYO_KOKA THEN
      -- 公課証明書: 土地・家屋
      o_kbn_list.EXTEND; o_kbn_list(o_kbn_list.LAST) := C_KBN_TOCHI;
      o_kbn_list.EXTEND; o_kbn_list(o_kbn_list.LAST) := C_KBN_KAOKU;
    ELSIF i_chohyo_kbn = C_CHOHYO_SHOKYA THEN
      -- 償却資産証明書: 償却資産のみ … のはずだが、下記の呼出側で
      --   実際には集計対象として扱われない（件数取得が未対応のため）。
      o_kbn_list.EXTEND; o_kbn_list(o_kbn_list.LAST) := C_KBN_SHOKYAKU;
    ELSE
      NULL;
    END IF;
  END p_get_target_kbn_list;

  ----------------------------------------------------------------------------
  -- 1明細（物件区分単位）の算出
  ----------------------------------------------------------------------------
  FUNCTION func_calc_one(i_year IN NUMBER, i_kbn IN VARCHAR2)
    RETURN T_KENSU_REC IS
    v_rec   T_KENSU_REC;
  BEGIN
    v_rec.bukken_kbn := i_kbn;
    v_rec.kensu      := func_get_kensu(i_year, i_kbn);   -- ★償却は常に0が返る
    v_rec.hyoka_gaku := func_get_hyoka(i_year, i_kbn);
    v_rec.kazei_hyo  := func_calc_kazei_hyojun(i_kbn, v_rec.hyoka_gaku);
    RETURN v_rec;
  END func_calc_one;

  ----------------------------------------------------------------------------
  -- メイン: 証明書1件分の 課税標準額・税額・件数 を計算
  --   O_NK_KENSU 等のOUT項目を帳票へ引き渡す。
  ----------------------------------------------------------------------------
  PROCEDURE p_calc_shomeisho(
    i_year        IN  NUMBER,
    i_chohyo_kbn  IN  VARCHAR2,
    o_kensu_total OUT PLS_INTEGER,
    o_kazei_total OUT NUMBER,
    o_zei_total   OUT NUMBER,
    o_status      OUT VARCHAR2
  ) IS
    v_kbn_list  SYS.ODCIVARCHAR2LIST;
    v_rec       T_KENSU_REC;
    v_zei       NUMBER;
  BEGIN
    o_kensu_total := 0;
    o_kazei_total := 0;
    o_zei_total   := 0;
    o_status      := 'OK';

    -- 対象物件区分の決定
    p_get_target_kbn_list(i_chohyo_kbn, v_kbn_list);
    IF v_kbn_list IS NULL OR v_kbn_list.COUNT = 0 THEN
      o_status := 'NO_TARGET';
      RETURN;
    END IF;

    -- 各物件区分を集計
    FOR i IN 1 .. v_kbn_list.COUNT LOOP
      v_rec := func_calc_one(i_year, v_kbn_list(i));

      o_kensu_total := o_kensu_total + NVL(v_rec.kensu, 0);
      o_kazei_total := o_kazei_total + NVL(v_rec.kazei_hyo, 0);
      v_zei         := func_calc_zeigaku(v_rec.bukken_kbn, v_rec.kazei_hyo, v_rec.kensu);
      o_zei_total   := o_zei_total + NVL(v_zei, 0);

      p_log('I', 'kbn=' || v_rec.bukken_kbn
                || ' kensu=' || v_rec.kensu
                || ' kazei=' || v_rec.kazei_hyo
                || ' zei=' || v_zei);
    END LOOP;

    -- 件数0のときは課税標準額・税額とも空欄相当（0）となる
    IF o_kensu_total = 0 THEN
      o_status := 'ZERO_KENSU';
    END IF;

  EXCEPTION
    WHEN OTHERS THEN
      o_status := 'ERROR';
      p_log('E', 'p_calc_shomeisho: ' || SQLERRM);
  END p_calc_shomeisho;

  ----------------------------------------------------------------------------
  -- 帳票出力用のフォーマット（金額→文字列）
  ----------------------------------------------------------------------------
  FUNCTION func_fmt_yen(i_val IN NUMBER)
    RETURN VARCHAR2 IS
  BEGIN
    IF i_val IS NULL THEN
      RETURN ''; -- NULLは空欄
    END IF;
    IF i_val = 0 THEN
      -- 0円は空欄ではなく「0」を明示… したいが現状は空欄運用
      RETURN '';
    END IF;
    RETURN TO_CHAR(i_val, 'FM999,999,999,990') || '円';
  END func_fmt_yen;

  ----------------------------------------------------------------------------
  -- 証明書発行のエントリポイント
  --   帳票明細を組み立てて返す。
  ----------------------------------------------------------------------------
  PROCEDURE p_issue_certificate(
    i_year       IN  NUMBER,
    i_chohyo_kbn IN  VARCHAR2,
    i_uketsuke   IN  VARCHAR2,
    o_kazei_disp OUT VARCHAR2,
    o_zei_disp   OUT VARCHAR2,
    o_kensu_disp OUT VARCHAR2,
    o_result     OUT VARCHAR2
  ) IS
    v_kensu PLS_INTEGER;
    v_kazei NUMBER;
    v_zei   NUMBER;
    v_stat  VARCHAR2(20);
  BEGIN
    p_log('I', 'issue start: chohyo=' || i_chohyo_kbn || ' uketsuke=' || i_uketsuke);

    p_calc_shomeisho(i_year, i_chohyo_kbn, v_kensu, v_kazei, v_zei, v_stat);

    o_kensu_disp := TO_CHAR(NVL(v_kensu,0));
    o_kazei_disp := func_fmt_yen(v_kazei);
    o_zei_disp   := func_fmt_yen(v_zei);
    o_result     := v_stat;

    p_log('I', 'issue end: status=' || v_stat
              || ' kensu=' || v_kensu
              || ' kazei=' || v_kazei
              || ' zei=' || v_zei);
  EXCEPTION
    WHEN OTHERS THEN
      o_result := 'FATAL';
      p_log('E', 'p_issue_certificate: ' || SQLERRM);
  END p_issue_certificate;

  ----------------------------------------------------------------------------
  -- バッチ: 受付一覧に対する一括発行
  ----------------------------------------------------------------------------
  PROCEDURE p_batch_issue(i_year IN NUMBER) IS
    CURSOR c_uke IS
      SELECT UKETSUKE_NO, CHOHYO_KBN
      FROM   T_CERT_UKETSUKE
      WHERE  SHORI_ZUMI_FLG = '0'
      ORDER  BY UKETSUKE_NO;
    v_kazei_disp VARCHAR2(40);
    v_zei_disp   VARCHAR2(40);
    v_kensu_disp VARCHAR2(20);
    v_result     VARCHAR2(20);
    v_cnt        PLS_INTEGER := 0;
  BEGIN
    FOR r IN c_uke LOOP
      p_issue_certificate(
        i_year, r.CHOHYO_KBN, r.UKETSUKE_NO,
        v_kazei_disp, v_zei_disp, v_kensu_disp, v_result
      );
      -- 発行結果を更新
      UPDATE T_CERT_UKETSUKE
         SET SHORI_ZUMI_FLG = '1',
             KAZEI_DISP     = v_kazei_disp,
             ZEI_DISP       = v_zei_disp,
             KENSU_DISP     = v_kensu_disp,
             RESULT_CD      = v_result
       WHERE UKETSUKE_NO    = r.UKETSUKE_NO;
      v_cnt := v_cnt + 1;
    END LOOP;
    COMMIT;
    p_log('I', 'p_batch_issue done. count=' || v_cnt);
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_log('E', 'p_batch_issue: ' || SQLERRM);
      RAISE;
  END p_batch_issue;

  ----------------------------------------------------------------------------
  -- 保守用: 単票デバッグ出力
  ----------------------------------------------------------------------------
  PROCEDURE p_debug_one(i_year IN NUMBER, i_chohyo_kbn IN VARCHAR2) IS
    v_k VARCHAR2(40); v_z VARCHAR2(40); v_c VARCHAR2(20); v_r VARCHAR2(20);
  BEGIN
    p_issue_certificate(i_year, i_chohyo_kbn, 'DEBUG', v_k, v_z, v_c, v_r);
    DBMS_OUTPUT.PUT_LINE('kazei=' || v_k || ' zei=' || v_z
                      || ' kensu=' || v_c || ' result=' || v_r);
  END p_debug_one;

  ----------------------------------------------------------------------------
  -- 負担調整率の算出（土地）
  --   前年度課税標準額と当年度評価額の比率から負担水準を求め、
  --   負担調整措置の調整率を返す。家屋・償却では使用しない。
  ----------------------------------------------------------------------------
  FUNCTION func_futan_chosei_ritsu(
    i_zen_kazei IN NUMBER,
    i_tou_hyoka IN NUMBER
  ) RETURN NUMBER IS
    v_futan_suijun NUMBER;
    v_ritsu        NUMBER;
  BEGIN
    IF i_tou_hyoka IS NULL OR i_tou_hyoka = 0 THEN
      RETURN 1.0;
    END IF;
    v_futan_suijun := i_zen_kazei / i_tou_hyoka;
    -- 負担水準に応じた調整（住宅用地の例）
    IF v_futan_suijun >= 1.0 THEN
      v_ritsu := 1.0;
    ELSIF v_futan_suijun >= 0.9 THEN
      v_ritsu := 0.975;
    ELSIF v_futan_suijun >= 0.8 THEN
      v_ritsu := 0.95;
    ELSE
      -- なだらかに引き上げ
      v_ritsu := v_futan_suijun + 0.05;
      IF v_ritsu > 1.0 THEN
        v_ritsu := 1.0;
      END IF;
    END IF;
    RETURN v_ritsu;
  EXCEPTION WHEN OTHERS THEN
    p_log('E', 'func_futan_chosei_ritsu: ' || SQLERRM);
    RETURN 1.0;
  END func_futan_chosei_ritsu;

  ----------------------------------------------------------------------------
  -- 年度別の特例税率取得
  --   条例改正等により年度で税率が異なる場合に対応。
  ----------------------------------------------------------------------------
  FUNCTION func_get_zeiritsu(i_year IN NUMBER, i_kbn IN VARCHAR2)
    RETURN NUMBER IS
    v_ritsu NUMBER;
  BEGIN
    -- 原則は標準税率
    v_ritsu := C_TAX_RATE;
    -- 特定年度の経過措置（サンプル）
    IF i_year <= 2020 THEN
      v_ritsu := 0.015;
    END IF;
    -- 償却資産は一部設備で特例（1/2等）があるが、ここでは標準に集約
    RETURN v_ritsu;
  END func_get_zeiritsu;

  ----------------------------------------------------------------------------
  -- 所有者情報の取得
  ----------------------------------------------------------------------------
  FUNCTION func_get_owner_nm(i_year IN NUMBER, i_uketsuke IN VARCHAR2)
    RETURN VARCHAR2 IS
    v_nm VARCHAR2(120);
  BEGIN
    BEGIN
      SELECT OWNER_MEISHO
        INTO v_nm
        FROM T_CERT_UKETSUKE
       WHERE UKETSUKE_NO = i_uketsuke;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        v_nm := NULL;
    END;
    RETURN v_nm;
  END func_get_owner_nm;

  ----------------------------------------------------------------------------
  -- 名寄せキーの正規化（連名帳対応）
  --   大字・小字・地番の表記ゆれを吸収する。
  ----------------------------------------------------------------------------
  FUNCTION func_normalize_nayose_key(
    i_ooaza IN VARCHAR2,
    i_koaza IN VARCHAR2,
    i_chiban IN VARCHAR2
  ) RETURN VARCHAR2 IS
    v_key VARCHAR2(300);
  BEGIN
    v_key := TRIM(NVL(i_ooaza, ' '))
          || '|' || TRIM(NVL(i_koaza, ' '))
          || '|' || TRIM(NVL(i_chiban, ' '));
    -- 全角空白除去
    v_key := REPLACE(v_key, '　', '');
    RETURN UPPER(v_key);
  END func_normalize_nayose_key;

  ----------------------------------------------------------------------------
  -- 課税明細の1行を組み立て（帳票用）
  ----------------------------------------------------------------------------
  FUNCTION func_build_meisai_line(
    i_kbn      IN VARCHAR2,
    i_kensu    IN PLS_INTEGER,
    i_kazei    IN NUMBER,
    i_zei      IN NUMBER
  ) RETURN VARCHAR2 IS
    v_kbn_nm VARCHAR2(20);
    v_line   VARCHAR2(400);
  BEGIN
    IF i_kbn = C_KBN_TOCHI THEN
      v_kbn_nm := '土地';
    ELSIF i_kbn = C_KBN_KAOKU THEN
      v_kbn_nm := '家屋';
    ELSIF i_kbn = C_KBN_SHOKYAKU THEN
      v_kbn_nm := '償却資産';
    ELSE
      v_kbn_nm := '不明';
    END IF;

    v_line := RPAD(v_kbn_nm, 10)
           || ' 件数:' || LPAD(TO_CHAR(NVL(i_kensu,0)), 6)
           || ' 課税標準:' || func_fmt_yen(i_kazei)
           || ' 税額:' || func_fmt_yen(i_zei);
    RETURN v_line;
  END func_build_meisai_line;

  ----------------------------------------------------------------------------
  -- 課税明細の全行を組み立て（帳票ボディ）
  --   対象物件区分を走査し、明細行を連結して返す。
  --   ※ 対象物件区分は p_get_target_kbn_list に依存するため、
  --     償却資産証明書であっても件数取得が未対応だと明細は0件表示となる。
  ----------------------------------------------------------------------------
  PROCEDURE p_build_meisai_body(
    i_year       IN  NUMBER,
    i_chohyo_kbn IN  VARCHAR2,
    o_body       OUT CLOB
  ) IS
    v_kbn_list SYS.ODCIVARCHAR2LIST;
    v_rec      T_KENSU_REC;
    v_zei      NUMBER;
    v_line     VARCHAR2(400);
  BEGIN
    DBMS_LOB.CREATETEMPORARY(o_body, TRUE);
    p_get_target_kbn_list(i_chohyo_kbn, v_kbn_list);
    IF v_kbn_list IS NULL OR v_kbn_list.COUNT = 0 THEN
      RETURN;
    END IF;

    FOR i IN 1 .. v_kbn_list.COUNT LOOP
      v_rec := func_calc_one(i_year, v_kbn_list(i));
      v_zei := func_calc_zeigaku(v_rec.bukken_kbn, v_rec.kazei_hyo, v_rec.kensu);
      v_line := func_build_meisai_line(v_rec.bukken_kbn, v_rec.kensu, v_rec.kazei_hyo, v_zei);
      DBMS_LOB.APPEND(o_body, v_line || CHR(10));
    END LOOP;
  EXCEPTION
    WHEN OTHERS THEN
      p_log('E', 'p_build_meisai_body: ' || SQLERRM);
  END p_build_meisai_body;

  ----------------------------------------------------------------------------
  -- 旧実装（廃止・コメントアウト）:
  --   かつては帳票種別ごとに件数SQLをハードコードしていた。
  --   FUNCTION func_kensu_hyoka_old(i_chohyo IN VARCHAR2) ...
  --     IF i_chohyo = '110' THEN  -- 評価証明書
  --       ... 土地・家屋のみ ...
  --     ELSIF i_chohyo = '120' THEN  -- 公課証明書
  --       ... 土地・家屋のみ ...
  --     END IF;
  --   ※ 償却資産証明書(130)の分岐は当時から存在しなかった。
  --   現在はディスパッチ方式に移行したが、件数取得(func_get_kensu)側の
  --   区分対応漏れは引き継がれている。
  ----------------------------------------------------------------------------

  ----------------------------------------------------------------------------
  -- 整合性チェック（保守用）:
  --   対象物件区分に対して件数取得関数が定義されているかを点検する。
  --   本来はここで償却資産の未対応を検知できるはずだが、
  --   チェック対象が土地・家屋に限定されているため見逃されている。
  ----------------------------------------------------------------------------
  PROCEDURE p_self_check(o_ng_cnt OUT PLS_INTEGER) IS
    v_sql VARCHAR2(4000);
    v_ret PLS_INTEGER;
  BEGIN
    o_ng_cnt := 0;
    -- 土地
    v_ret := func_sql_cre_02_tochi('DUMMY', v_sql);
    IF v_sql IS NULL THEN o_ng_cnt := o_ng_cnt + 1; END IF;
    -- 家屋
    v_ret := func_sql_cre_03_kaoku('DUMMY', v_sql);
    IF v_sql IS NULL THEN o_ng_cnt := o_ng_cnt + 1; END IF;
    -- ※ 償却資産の件数取得関数はチェック対象に含まれていない
  END p_self_check;

END PKG_ZEI_CERT_CALC;
/
