#!/usr/bin/env python3
"""Chrome の専用プロファイルに Memory Saver の設定を書く(起動前に実行する)。

Codex 調査より: ON/OFF と強度は `Local State` の performance_tuning.high_efficiency_mode、
破棄の例外は `Default/Preferences` の performance_tuning.tab_discarding。
state 0=OFF / 2=ON、aggressiveness 0=Moderate / 1=Balanced / 2=Maximum。
"""
import json, os, sys

prof, state = sys.argv[1], int(sys.argv[2])
os.makedirs(os.path.join(prof, "Default"), exist_ok=True)

ls_path = os.path.join(prof, "Local State")
ls = json.load(open(ls_path)) if os.path.exists(ls_path) else {}
ls.setdefault("performance_tuning", {})["high_efficiency_mode"] = {"state": state, "aggressiveness": 2}
json.dump(ls, open(ls_path, "w"))

pf_path = os.path.join(prof, "Default", "Preferences")
pf = json.load(open(pf_path)) if os.path.exists(pf_path) else {}
pf.setdefault("performance_tuning", {})["tab_discarding"] = {"exceptions": [], "exceptions_with_time": {}}
json.dump(pf, open(pf_path, "w"))
print(f"memory saver state={state} aggressiveness=2 -> {prof}")
