# nextpnr の Gowin のタイミング解析の死角

このプロジェクトの 3D GPU (`make bitstream-gpu3d`) で、nextpnr の報告では間に合っているのに実機の絵が化け、化ける場所が配置の種で変わった
(docs/GPU3D_PLAN.md の G3・G5 のあと)。原因を調べた結果のまとめと、上流 (YosysHQ/nextpnr) に出す報告の下書き。

- 使っている版: `nextpnr-0.11.1-40-geb4f15c3` (`tang-fpga` イメージ、2026-09-29 のコミット eb4f15c3)。master は 2026-10-26 の dd574dd まで見た
- 対象: `himbaechel/uarch/gowin/gowin_arch_gen.py` (チップの DB を作るときに、セルのタイミングの弧を登録するところ)

## 1. 真のデュアルポート BSRAM の B ポートの番地 (ADB) が登録されていない (ソースで確かめた)

`gowin_arch_gen.py` の BSRAM のタイミングの登録で、DP 系 (`DP` `DPX9` `DPB` `DPX9B`) のループの中の 1 行だけが、ループの変数 `dp` でなく
1 つ前の SP 系のループの変数 `sp` を使っている:

```python
                for dp_type in ("DP", "DPX9", "DPB", "DPX9B"):
                    dp = tmg.add_cell_variant(speed, dp_type)
                    ...
                    add_bram_bus_input(dp, "CLKA", "ADA", 14, "clka_ada")
                    add_bram_bus_input(sp, "CLKB", "ADB", 14, "clkb_adb")      # ← dp のはず
```

(master の 2061 行、eb4f15c3 では 2052 行)

- `sp` は SP 系のループの最後の変種 (`SPX9`) を指したまま。DP 系のセルには `ADB0..13` のセットアップ / ホールドの弧がなく、`SPX9` には存在しないピンの弧が付く
- 結果: **DP の BSRAM の B ポートの番地に入る経路は、タイミング解析の終点にならない**。番地の前に論理があっても Fmax の報告に出ない
- yosys の `synth_gowin` は、幅が 18bit 以下の RAM を DP (`DPX9B`) に置く (`brams.txt`: DP の幅は 18 まで、SDP は 36 まで、費用は同じ)。
  このプロジェクトでは色と Z のタイルバッファ、CLUT、リスト、タイルの数がそうなる
- 直し方: `sp` → `dp` の 1 文字

### 1.1 eb4f15c3 にはもう 1 つ (master では直っている)

同じ DP のループで、B ポートの出力が `DOB` でなく `DO` の名前で登録されている (`add_bram_bus_output(dp, "CLKB", "DO", ...)`、2048 行)。
DP のセルのピンは `DOB0..` なので、B ポートの出力の clock-to-out の弧もない。master は `DOB` になっている。

## 2. 配線のあとの解析が、長い組み合わせの経路を落とす (観測。原因は未確認)

最小の再現 ([`tools/repro/nextpnr_gowin_timing/`](../tools/repro/nextpnr_gowin_timing/)、`make timing-repro`):
FF から、依存し合う 32bit の足し算 30 段 (間に回転と XOR) の組み合わせを作り、その結果を BSRAM の番地か FF で受ける。この経路は数十 ns あるはず。

| 受けるところ | 配置のあとの Max frequency | 配線のあとの Max frequency |
|---|---|---|
| DP (`DPX9B`) の読み出しの番地 (ADB) | 11.72 MHz | 250.94 MHz |
| DP の書き込みの番地 (ADA) | 12.02 MHz | 318.88 MHz |
| SDP (`SDPX9B`) の読み出しの番地 (ADB) | 11.89 MHz | 173.73 MHz |
| SDP の書き込みの番地 (ADA) | 12.32 MHz | 186.85 MHz |
| **対照: 普通の FF** | 11.95 MHz | 275.63 MHz |

- 配置のあと (配線の遅れは見積もり) は 30 段の経路が律速で約 12MHz。**配線のあとは、対照の FF で受けた場合も含めてどれもこの経路が消え**、
  短い経路 (`b + a` の 1 段の足し算、BSRAM の出力から LED) が最悪として報告される
- 1 章の ADB の問題とは別。BSRAM に限らない。G3 で「長い桁上げの連鎖は報告より遅い」と見えていたのは、これかもしれない
- 原因の候補 (確かめていない): 配線で LUT / ALU の入力のピンの割り当てが入れ替わり、そのピンの弧が見つからなくなる、など

### 2.1 このプロジェクトの 3D GPU の 2 つの数字

`build/gpu3d/top_nextpnr.log` の `clk_sys` (63MHz で動かしている): **配置のあと 66.9MHz、配線のあと 105.8MHz** (#42 の時点)。
配置のあとの見積もりは配線の遅れを見積もるので悲観的なことがあるが、経路を落とさない。63MHz に対して余裕は小さい。

## 3. このプロジェクトでの扱い

- DP の BSRAM の番地は、両方のポートとも FF から直接 (`scripts/bsram_check.py` が合成したネットリストで確かめ、`make bitstream-gpu3d` で違反なら止まる)
- 2 章のため、「SDP なら番地に論理を挟んでもタイミングを見てくれる」とは言い切れない。テクスチャのキャッシュのタグの RAM (SDP) は、
  番地を組み合わせ (次のピクセルのワードアドレス) で読んでいる。2 つの配置で実機は合っているが、ここも FF から直接にできるか検討する
- **配置のあとの Max frequency も見る**。配線のあとの数字だけで「間に合っている」と言わない。配置のあとの数字が `clk_sys` (63MHz) を下回ったら疑う
- 完了は 2 つ以上の種で実機を 2 回ずつ (CLAUDE.md)

## 4. 上流への報告の下書き (英語)

> **gowin: DP BSRAM port-B address (ADB) timing arcs are registered on the SP cell variant**
>
> In `himbaechel/uarch/gowin/gowin_arch_gen.py`, inside the `for dp_type in ("DP", "DPX9", "DPB", "DPX9B")` loop, the ADB setup/hold arcs are added to `sp` instead of `dp`:
>
> ```python
> add_bram_bus_input(sp, "CLKB", "ADB", 14, "clkb_adb")   # should be dp
> ```
>
> `sp` still refers to the last SP variant (`SPX9`), so DP/DPX9/DPB/DPX9B cells get no timing arcs on `ADB0..13`, and paths into the port-B address of a true dual-port BSRAM are never timing endpoints. yosys `synth_gowin` maps RAMs up to 18 bits wide to DPX9B, so this affects common designs. We saw silent data corruption on hardware (GW2AR-18, Tang Nano 20K) that moved with the placement seed while the reported Fmax had margin; registering the read address in a flip-flop with no logic before ADB fixed it.
>
> (nextpnr-0.11.1-40-geb4f15c3 also registered the DP port-B output as `DO` instead of `DOB`; that is already fixed on master.)
>
> Separately, we observe that in a small design with a 30-stage combinational adder chain, the post-placement Fmax is ~12 MHz (the chain) but the post-route report drops the chain entirely (175–320 MHz), even when the chain ends in a plain DFF. Reproduction: (attach `repro.sv`, `repro.cst`, `run.sh`). We have not identified the cause.
