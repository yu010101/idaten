// adblock-rust(MPL-2.0)をビルド時だけ呼び、WKContentRuleList用のJSONを生成するCLI。
// Karu本体(MIT)には静的リンクしない——変換済みJSONだけを同梱する(Codexとの検討、2026-09-20)。
// 使い方: adblock-convert <入力フィルタファイル>... <出力JSONパス>
use adblock::lists::{FilterSet, ParseOptions};
use std::env;
use std::fs;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.len() < 2 {
        eprintln!("usage: adblock-convert <入力フィルタファイル>... <出力JSONパス>");
        return ExitCode::FAILURE;
    }
    let (inputs, output) = args.split_at(args.len() - 1);
    let output_path = &output[0];

    // debug=true が無いと into_content_blocking() が Err(()) を返す(実装で確認済み)
    let mut filter_set = FilterSet::new(true);
    let mut total_lines = 0usize;
    for path in inputs {
        let text = match fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) => { eprintln!("読み込み失敗 {}: {}", path, e); return ExitCode::FAILURE; }
        };
        total_lines += text.lines().count();
        filter_set.add_filter_list(text, ParseOptions::default());
        eprintln!("読み込み: {}", path);
    }

    let (rules, converted) = match filter_set.into_content_blocking() {
        Ok(r) => r,
        Err(()) => { eprintln!("変換失敗(debugモードでないFilterSet)"); return ExitCode::FAILURE; }
    };

    let json = match serde_json::to_string_pretty(&rules) {
        Ok(j) => j,
        Err(e) => { eprintln!("JSON化失敗: {}", e); return ExitCode::FAILURE; }
    };
    if let Err(e) = fs::write(output_path, &json) {
        eprintln!("書き込み失敗 {}: {}", output_path, e);
        return ExitCode::FAILURE;
    }

    eprintln!(
        "完了: 入力行数={} 変換成功フィルタ数={} 生成ルール数={} 出力={}",
        total_lines, converted.len(), rules.len(), output_path
    );
    // WKContentRuleList 1リストの上限150,000ルール(調査で確認済み)。超えたら分割が要ることを警告する
    if rules.len() > 150_000 {
        eprintln!("警告: 150,000ルールを超えています。WKContentRuleListStoreは1リストにつきこの上限を超えると");
        eprintln!("コンパイル失敗する。ファイルを分割すること。");
    }
    ExitCode::SUCCESS
}
