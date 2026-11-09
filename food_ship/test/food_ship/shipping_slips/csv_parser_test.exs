defmodule FoodShip.ShippingSlips.CsvParserTest do
  use ExUnit.Case, async: true

  alias FoodShip.ShippingSlips.CsvParser

  @header "client_code,client_slip_no,scheduled_ship_date,item_code,order_count"

  test "見出し行を除いて、行番号つきで返す" do
    csv = "#{@header}\nC1,A-1,2026-11-20,I1,3\nC1,A-2,2026-11-21,I2,5\n"

    assert {:ok, rows} = CsvParser.parse(csv)

    assert rows == [
             %{line: 2, fields: ["C1", "A-1", "2026-11-20", "I1", "3"]},
             %{line: 3, fields: ["C1", "A-2", "2026-11-21", "I2", "5"]}
           ]
  end

  test "BOM 付き・CRLF・末尾の改行なし・空行・項目の前後の空白を扱う" do
    csv = "﻿#{@header}\r\n\r\n C1 , A-1 ,2026-11-20,I1,3\r\n\r\nC2,A-2,2026-11-21,I2,4"

    assert {:ok, rows} = CsvParser.parse(csv)

    assert rows == [
             %{line: 3, fields: ["C1", "A-1", "2026-11-20", "I1", "3"]},
             %{line: 5, fields: ["C2", "A-2", "2026-11-21", "I2", "4"]}
           ]
  end

  test "ダブルクォートの中のカンマ・改行・エスケープされた引用符。行番号はレコードの開始行" do
    csv = "#{@header}\n\"C,1\",\"A\n1\",2026-11-20,\"I\"\"1\",3\nC2,A-2,2026-11-21,I2,4\n"

    assert {:ok, rows} = CsvParser.parse(csv)

    assert rows == [
             %{line: 2, fields: ["C,1", "A\n1", "2026-11-20", "I\"1", "3"]},
             %{line: 4, fields: ["C2", "A-2", "2026-11-21", "I2", "4"]}
           ]
  end

  test "見出しは大文字小文字を区別しない。列数の不一致の行は、そのまま返す" do
    csv = "Client_Code,Client_Slip_No,Scheduled_Ship_Date,Item_Code,Order_Count\nC1,A-1\n"

    assert {:ok, [%{line: 2, fields: ["C1", "A-1"]}]} = CsvParser.parse(csv)
  end

  test "見出しが違う・空のファイルはエラー" do
    assert {:error, "1 行目の見出しが正しくありません" <> _} =
             CsvParser.parse("code,slip,date,item,count\nC1,A-1,2026-11-20,I1,3\n")

    assert {:error, "1 行目の見出しが正しくありません" <> _} = CsvParser.parse("")
  end

  test "データ行がなければエラー" do
    assert {:error, "データ行がありません。"} = CsvParser.parse("#{@header}\n\n")
  end

  test "UTF-8 でないファイル(Shift_JIS など)はエラー" do
    sjis = <<0x93, 0xFA, 0x96, 0x7B>>

    assert {:error, "UTF-8 の文字コードで保存し直してください。"} =
             CsvParser.parse("#{@header}\nC1,#{sjis},2026-11-20,I1,3\n")
  end

  test "閉じられていないダブルクォートはエラー" do
    assert {:error, "ダブルクォートが閉じられていません。"} =
             CsvParser.parse("#{@header}\nC1,\"A-1,2026-11-20,I1,3\n")
  end

  test "行数の上限(2,000 行)" do
    row = "C1,A-1,2026-11-20,I1,3\n"

    assert {:ok, rows} = CsvParser.parse(@header <> "\n" <> String.duplicate(row, 2_000))
    assert length(rows) == 2_000

    assert {:error, "行数が多すぎます(上限 2000 行)。"} =
             CsvParser.parse(@header <> "\n" <> String.duplicate(row, 2_001))
  end

  test "ファイルサイズの上限(1 MB)" do
    big = @header <> "\n" <> String.duplicate("x", CsvParser.max_bytes())

    assert {:error, "ファイルが大きすぎます(上限 1 MB)。"} = CsvParser.parse(big)
  end
end
