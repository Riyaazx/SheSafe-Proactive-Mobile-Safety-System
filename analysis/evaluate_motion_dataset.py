"""
evaluate_motion_dataset.py
==========================
Offline analysis of the motion dataset exported from the SheSafe app
(Settings → Motion Dataset → Export CSV).

Computes per-class and overall:
  • Recall   (primary metric — missing a real threat is costlier than a false alarm)
  • Precision
  • F1-score
  • Feature-extraction latency proxy

Also produces:
  • Confusion matrix heatmap
  • Per-feature distribution plots (normal vs anomaly classes)
  • ROC curve (one-vs-rest for anomaly vs normal)

Usage
-----
    python analysis/evaluate_motion_dataset.py --csv path/to/dataset.csv

Dependencies
------------
    pip install pandas scikit-learn matplotlib seaborn
"""

import argparse
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import seaborn as sns
from sklearn.metrics import (
    ConfusionMatrixDisplay,
    classification_report,
    confusion_matrix,
    roc_auc_score,
    roc_curve,
)

# ── Constants ──────────────────────────────────────────────────────────────────

NORMAL_LABEL = "normal_walk"
ANOMALY_LABELS = ["sudden_stop", "fast_turn", "short_run", "phone_shake"]
ALL_LABELS = [NORMAL_LABEL] + ANOMALY_LABELS

FEATURE_COLS = [
    "mean_magnitude",
    "std_magnitude",
    "variance",
    "sma",
    "mean_jerk",
    "peak_magnitude",
    "zero_crossings",
]

LABEL_COLORS = {
    "normal_walk": "#2ca02c",
    "sudden_stop": "#d62728",
    "fast_turn":   "#ff7f0e",
    "short_run":   "#1f77b4",
    "phone_shake": "#9467bd",
}


# ── Data loading ───────────────────────────────────────────────────────────────

def load_dataset(csv_path: str) -> pd.DataFrame:
    df = pd.read_csv(csv_path)

    required = {"label", "is_anomaly", "detected_as_anomaly"} | set(FEATURE_COLS)
    missing = required - set(df.columns)
    if missing:
        print(f"[ERROR] CSV is missing columns: {missing}", file=sys.stderr)
        print(f"        Available columns: {list(df.columns)}", file=sys.stderr)
        sys.exit(1)

    df["is_anomaly"] = df["is_anomaly"].astype(int)
    df["detected_as_anomaly"] = (
        pd.to_numeric(df["detected_as_anomaly"], errors="coerce").fillna(0).astype(int)
    )

    # Anomaly score may be empty before evaluation
    if "anomaly_score" in df.columns:
        df["anomaly_score"] = pd.to_numeric(df["anomaly_score"], errors="coerce")

    return df


# ── Metrics ────────────────────────────────────────────────────────────────────

def compute_binary_metrics(df: pd.DataFrame) -> dict:
    """Compute overall binary (anomaly vs normal) metrics."""
    y_true = df["is_anomaly"]
    y_pred = df["detected_as_anomaly"]

    tn, fp, fn, tp = confusion_matrix(y_true, y_pred, labels=[0, 1]).ravel()
    precision = tp / (tp + fp) if (tp + fp) > 0 else 0.0
    recall    = tp / (tp + fn) if (tp + fn) > 0 else 0.0
    f1        = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0.0
    specificity = tn / (tn + fp) if (tn + fp) > 0 else 0.0

    return {
        "tp": int(tp), "fp": int(fp), "tn": int(tn), "fn": int(fn),
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "specificity": specificity,
    }


def compute_per_class_metrics(df: pd.DataFrame) -> pd.DataFrame:
    """Recall / precision / F1 for each class independently."""
    rows = []
    for label in ALL_LABELS:
        sub = df[df["label"] == label]
        if sub.empty:
            continue
        expected_anomaly = int(label != NORMAL_LABEL)
        tp = int(((sub["is_anomaly"] == 1) & (sub["detected_as_anomaly"] == 1)).sum())
        fp = int(((sub["is_anomaly"] == 0) & (sub["detected_as_anomaly"] == 1)).sum())
        tn = int(((sub["is_anomaly"] == 0) & (sub["detected_as_anomaly"] == 0)).sum())
        fn = int(((sub["is_anomaly"] == 1) & (sub["detected_as_anomaly"] == 0)).sum())
        precision  = tp / (tp + fp) if (tp + fp) > 0 else float("nan")
        recall     = tp / (tp + fn) if (tp + fn) > 0 else float("nan")
        f1         = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else float("nan")
        rows.append({
            "label": label,
            "type": "anomaly" if expected_anomaly else "normal",
            "n_samples": len(sub),
            "tp": tp, "fp": fp, "tn": tn, "fn": fn,
            "recall": recall,
            "precision": precision,
            "f1": f1,
        })
    return pd.DataFrame(rows).set_index("label")


# ── Latency ────────────────────────────────────────────────────────────────────

def latency_summary(df: pd.DataFrame) -> None:
    """Print a basic latency proxy table (timestamp diffs within each session)."""
    if "timestamp" not in df.columns:
        print("[WARNING] No timestamp column — latency analysis skipped.")
        return

    df = df.copy()
    df["timestamp"] = pd.to_datetime(df["timestamp"], errors="coerce")
    df = df.sort_values(["session_id", "timestamp"]) if "session_id" in df.columns else df.sort_values("timestamp")
    df["latency_ms"] = df.groupby("session_id")["timestamp"].diff().dt.total_seconds() * 1000

    print("\n── Latency proxy (window-to-window gap) ────────────────────")
    print(df["latency_ms"].describe().round(2).to_string())

    # If the app logged anomaly_score (post-evaluation), that's the detector score, not feature-extraction time.
    # Actual feature-extraction latency is sub-millisecond on modern phones.
    print("\nNote: latency here = time between successive 1-second windows.")
    print("      Feature-extraction latency < 1 ms (see in-app evaluation).")


# ── Plots ──────────────────────────────────────────────────────────────────────

def plot_confusion_matrix(df: pd.DataFrame, out_dir: Path) -> None:
    y_true = df["is_anomaly"]
    y_pred = df["detected_as_anomaly"]
    cm = confusion_matrix(y_true, y_pred, labels=[0, 1])
    disp = ConfusionMatrixDisplay(
        confusion_matrix=cm,
        display_labels=["normal", "anomaly"],
    )
    fig, ax = plt.subplots(figsize=(5, 4))
    disp.plot(ax=ax, colorbar=False, cmap="Blues")
    ax.set_title("Confusion Matrix (binary)")
    plt.tight_layout()
    path = out_dir / "confusion_matrix.png"
    fig.savefig(path, dpi=150)
    print(f"[✓] Saved {path}")
    plt.close(fig)


def plot_feature_distributions(df: pd.DataFrame, out_dir: Path) -> None:
    """Violin plots for each feature, split normal vs anomaly."""
    fig, axes = plt.subplots(2, 4, figsize=(18, 8))
    axes = axes.flatten()

    for i, col in enumerate(FEATURE_COLS):
        ax = axes[i]
        subset = {
            lbl: df.loc[df["label"] == lbl, col].dropna().values
            for lbl in ALL_LABELS if (df["label"] == lbl).any()
        }
        colors = [LABEL_COLORS.get(lbl, "grey") for lbl in subset]
        parts = ax.violinplot(
            list(subset.values()),
            showmedians=True,
            vert=True,
        )
        for patch, col_c in zip(parts["bodies"], colors):
            patch.set_facecolor(col_c)
            patch.set_alpha(0.7)
        ax.set_xticks(range(1, len(subset) + 1))
        ax.set_xticklabels(list(subset.keys()), rotation=25, ha="right", fontsize=8)
        ax.set_title(col, fontsize=11)
        ax.grid(axis="y", alpha=0.3)

    # Hide spare subplot
    for j in range(len(FEATURE_COLS), len(axes)):
        axes[j].set_visible(False)

    plt.suptitle("Feature Distributions per Motion Class", fontsize=14, fontweight="bold")
    plt.tight_layout()
    path = out_dir / "feature_distributions.png"
    fig.savefig(path, dpi=150)
    print(f"[✓] Saved {path}")
    plt.close(fig)


def plot_roc_curve(df: pd.DataFrame, out_dir: Path) -> None:
    """ROC curve using anomaly_score if available, else skip."""
    if "anomaly_score" not in df.columns or df["anomaly_score"].isna().all():
        print("[INFO] anomaly_score column empty — skipping ROC curve.")
        return

    y_true = df["is_anomaly"]
    y_score = df["anomaly_score"].fillna(0)

    if y_true.nunique() < 2:
        print("[INFO] Only one class present — skipping ROC curve.")
        return

    fpr, tpr, _ = roc_curve(y_true, y_score)
    auc = roc_auc_score(y_true, y_score)

    fig, ax = plt.subplots(figsize=(6, 5))
    ax.plot(fpr, tpr, lw=2, label=f"AUC = {auc:.3f}", color="#1f77b4")
    ax.plot([0, 1], [0, 1], "k--", lw=1)
    ax.set_xlabel("False Positive Rate (1 – Specificity)")
    ax.set_ylabel("True Positive Rate (Recall)")
    ax.set_title("ROC Curve — Anomaly vs Normal")
    ax.legend()
    ax.grid(alpha=0.3)
    plt.tight_layout()
    path = out_dir / "roc_curve.png"
    fig.savefig(path, dpi=150)
    print(f"[✓] Saved {path}")
    plt.close(fig)


def plot_recall_by_class(metrics_df: pd.DataFrame, out_dir: Path) -> None:
    fig, ax = plt.subplots(figsize=(7, 4))
    labels = metrics_df.index.tolist()
    recalls = metrics_df["recall"].tolist()
    colors = [LABEL_COLORS.get(lbl, "grey") for lbl in labels]

    bars = ax.bar(labels, recalls, color=colors, edgecolor="black", linewidth=0.6)
    ax.axhline(0.8, color="red", linestyle="--", linewidth=1.2, label="80 % target")
    ax.set_ylim(0, 1.1)
    ax.set_ylabel("Recall")
    ax.set_title("Recall per Motion Class", fontweight="bold")
    ax.legend()
    for bar, val in zip(bars, recalls):
        if not np.isnan(val):
            ax.text(bar.get_x() + bar.get_width() / 2, val + 0.02,
                    f"{val:.0%}", ha="center", va="bottom", fontsize=10)
    plt.xticks(rotation=20, ha="right")
    plt.tight_layout()
    path = out_dir / "recall_by_class.png"
    fig.savefig(path, dpi=150)
    print(f"[✓] Saved {path}")
    plt.close(fig)


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate SheSafe motion dataset")
    parser.add_argument("--csv", required=True, help="Path to the exported CSV file")
    parser.add_argument(
        "--out", default="analysis/results",
        help="Output directory for plots (default: analysis/results)"
    )
    args = parser.parse_args()

    csv_path = Path(args.csv)
    if not csv_path.exists():
        print(f"[ERROR] File not found: {csv_path}", file=sys.stderr)
        sys.exit(1)

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"  SheSafe Motion Dataset Evaluation")
    print(f"  Input : {csv_path}")
    print(f"  Output: {out_dir}")
    print(f"{'='*60}\n")

    df = load_dataset(str(csv_path))
    print(f"Loaded {len(df)} samples from {df['label'].nunique()} classes\n")
    print(df["label"].value_counts().to_string())

    # ── Binary metrics ─────────────────────────────────────────────────────
    has_predictions = df["detected_as_anomaly"].notna().any() and df["detected_as_anomaly"].sum() > 0

    if has_predictions:
        print("\n── Binary (Anomaly vs Normal) ───────────────────────────────")
        bm = compute_binary_metrics(df)
        print(f"  TP={bm['tp']}  FP={bm['fp']}  TN={bm['tn']}  FN={bm['fn']}")
        print(f"  Recall (sensitivity): {bm['recall']:.3f}   ← priority metric")
        print(f"  Precision           : {bm['precision']:.3f}")
        print(f"  F1-score            : {bm['f1']:.3f}")
        print(f"  Specificity         : {bm['specificity']:.3f}")

        # ── Per-class ──────────────────────────────────────────────────────
        print("\n── Per-class Metrics ────────────────────────────────────────")
        pc = compute_per_class_metrics(df)
        print(pc[["type", "n_samples", "recall", "precision", "f1"]].round(3).to_string())

        # ── sklearn report ─────────────────────────────────────────────────
        print("\n── Sklearn classification_report ───────────────────────────")
        print(classification_report(df["is_anomaly"], df["detected_as_anomaly"],
                                    target_names=["normal", "anomaly"]))

        # ── Plots ──────────────────────────────────────────────────────────
        plot_confusion_matrix(df, out_dir)
        plot_roc_curve(df, out_dir)
        plot_recall_by_class(pc, out_dir)
    else:
        print("\n[INFO] No anomaly predictions found in dataset.")
        print("       Run in-app Evaluate first, then re-export CSV.")
        pc = pd.DataFrame()

    # Feature distributions always available
    plot_feature_distributions(df, out_dir)

    # Latency
    latency_summary(df)

    print(f"\n{'='*60}")
    print(f"  Done!  Plots saved to {out_dir}/")
    print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
