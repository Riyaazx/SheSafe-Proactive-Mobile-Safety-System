"""
run_model_eval.py  (Walking-Based Evaluation — Three-Part Design)
=================================================================
Evaluates the SheSafe Isolation Forest model in three clearly separated parts.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PART 1 — REAL-DATA BASELINE  (primary / academically citable)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Uses only UCI HAR walking test windows (real recorded data, no anomaly labels).
Since no real anomaly recordings exist in this project, only the normal-class
performance can be honestly reported here:

  Normal class:  WALKING (1), WALKING_UPSTAIRS (2), WALKING_DOWNSTAIRS (3)
  Anomaly class: NONE — no real anomaly labels available

Metric reported: Specificity (True Negative Rate on walking windows).
  = proportion of real walking windows correctly accepted as normal.
This is the only unambiguous metric derivable from real data without
labelled anomaly examples. Recall / precision / AUC are NOT reported
in Part 1 because there is nothing to compute them against.

  EXCLUDED (out of scope for a walking safety app):
    SITTING (4), STANDING (5), LAYING (6)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PART 2 — SYNTHETIC STRESS TEST  (exploratory only — not final results)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
UCI HAR contains no falls, sudden stops, or fast turns.
This part generates synthetic anomaly windows by statistically perturbing
the real walking distribution in physically motivated ways.

PURPOSE: to verify that the Isolation Forest is sensitive to the kinds
of feature-space deviations that would occur during dangerous events.
This is NOT a validated accuracy measurement — it is a stress test
to check the model's directional anomaly sensitivity.

Anomaly types (synthetic):
  – simulated_fall      : extreme acceleration spike + jerk (impact event)
  – sudden_stop         : reversed acceleration + high jerk (deceleration)
  – fast_turn           : extreme gyroscope readings
  – high_jerk_impact    : large jerk across all axes

LIMITATION: Because anomalies are synthetic, the detection rates in Part 2
reflect how well the model separates the walking distribution from heavily
perturbed feature vectors — not from real dangerous movements. These numbers
MUST NOT be cited as real-world accuracy. They are indicative only.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PART 3 — THRESHOLD SENSITIVITY ANALYSIS  (real walking data only)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
The Isolation Forest flags a window as anomalous when:
    decision_function(x) < threshold   (default threshold = 0.0)

Part 3 moves this boundary and measures how the false alarm rate on real
walking windows changes. No synthetic data. No anomaly labels needed.

Threshold shifts tested (applied to decision_function output directly):
  Strictly stricter → fewer flags, lower false alarm rate, higher specificity
  Loosely stricter  → slightly fewer flags
  Default           → baseline (matches model.predict())
  Loosely looser    → slightly more flags
  Strictly looser   → more flags, higher false alarm rate, lower specificity

Outputs: threshold_sensitivity_results.csv
         threshold_sensitivity_plot.png

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Model & scaler: UNCHANGED.
app.py runtime logic: UNCHANGED.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Usage:
    python analysis/run_model_eval.py

Outputs:
    Console  : Part 1 baseline + Part 2 stress-test + Part 3 threshold table
    analysis/results/confusion_matrix_baseline.png  (Part 1)
    analysis/results/confusion_matrix_stress.png    (Part 2)
    analysis/results/roc_curve_stress.png           (Part 2)
    analysis/results/threshold_sensitivity_results.csv  (Part 3)
    analysis/results/threshold_sensitivity_plot.png     (Part 3)
"""

import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import joblib
from sklearn.metrics import (
    accuracy_score,
    confusion_matrix,
    ConfusionMatrixDisplay,
    roc_auc_score,
    roc_curve,
)

# ── Paths ──────────────────────────────────────────────────────────────────────
ROOT        = Path(__file__).parent.parent
UCI_TEST    = ROOT / "datasets" / "UCI_HAR" / "UCI HAR Dataset" / "test"
MODEL_PATH  = ROOT / "isolation_forest_model.pkl"
SCALER_PATH = ROOT / "scaler.pkl"
RESULTS_DIR = ROOT / "analysis" / "results"

# ── Feature configuration (identical to original — model unchanged) ────────────
FEATURE_NAMES = [
    'tBodyAcc-mean()-X', 'tBodyAcc-mean()-Y', 'tBodyAcc-mean()-Z',
    'tBodyAcc-std()-X',  'tBodyAcc-std()-Y',  'tBodyAcc-std()-Z',
    'tBodyAccJerk-mean()-X', 'tBodyAccJerk-mean()-Y', 'tBodyAccJerk-mean()-Z',
    'tBodyGyro-mean()-X', 'tBodyGyro-mean()-Y', 'tBodyGyro-mean()-Z',
    'tBodyGyro-std()-X',  'tBodyGyro-std()-Y',  'tBodyGyro-std()-Z',
]
FEATURE_COL_IDX = [0, 1, 2, 3, 4, 5, 80, 81, 82, 120, 121, 122, 123, 124, 125]

ACC_MEAN_IDX  = [0, 1, 2]
ACC_STD_IDX   = [3, 4, 5]
JERK_IDX      = [6, 7, 8]
GYRO_MEAN_IDX = [9, 10, 11]
GYRO_STD_IDX  = [12, 13, 14]

WALKING_IDS  = {1, 2, 3}
EXCLUDED_IDS = {4: "SITTING", 5: "STANDING", 6: "LAYING"}
ACTIVITY_NAMES = {
    1: "WALKING",
    2: "WALKING_UPSTAIRS",
    3: "WALKING_DOWNSTAIRS",
}

ANOMALY_TYPES = {
    "simulated_fall":   dict(acc_mult= 4.0, jerk_mult=6.0, gyro_mult=3.0),
    "sudden_stop":      dict(acc_mult=-3.0, jerk_mult=4.0, gyro_mult=1.5),
    "fast_turn":        dict(acc_mult= 1.5, jerk_mult=1.5, gyro_mult=6.0),
    "high_jerk_impact": dict(acc_mult= 2.5, jerk_mult=7.0, gyro_mult=2.0),
}
N_ANOMALY_PER_TYPE = 100

# ── Helpers ────────────────────────────────────────────────────────────────────

def _divider(char="─", width=70):
    print(char * width)


def _save_confusion_matrix(y_true, y_pred, labels, title, filename):
    cm = confusion_matrix(y_true, y_pred, labels=list(range(len(labels))))
    fig, ax = plt.subplots(figsize=(max(5, len(labels) * 1.4), max(4, len(labels) * 1.2)))
    ConfusionMatrixDisplay(confusion_matrix=cm, display_labels=labels).plot(
        ax=ax, colorbar=False, cmap="Blues"
    )
    ax.set_title(title, fontsize=9)
    plt.tight_layout()
    path = RESULTS_DIR / filename
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"   📊 Saved: {path.name}")


def _save_roc(y_true, anomaly_scores, auc, title, filename):
    try:
        fpr, tpr, _ = roc_curve(y_true, anomaly_scores)
        fig, ax = plt.subplots(figsize=(6, 5))
        ax.plot(fpr, tpr, lw=2, color="#1f77b4",
                label=f"Isolation Forest  AUC = {auc:.3f}")
        ax.plot([0, 1], [0, 1], "k--", lw=1, label="Random baseline")
        ax.set_xlabel("False Positive Rate (1 – Specificity)")
        ax.set_ylabel("True Positive Rate (Recall / Sensitivity)")
        ax.set_title(title, fontsize=10)
        ax.legend(loc="lower right")
        ax.grid(alpha=0.3)
        plt.tight_layout()
        path = RESULTS_DIR / filename
        fig.savefig(path, dpi=150)
        plt.close(fig)
        print(f"   📊 Saved: {path.name}")
    except Exception as exc:
        print(f"   [WARNING] ROC plot skipped: {exc}")


# ══════════════════════════════════════════════════════════════════════════════
# SETUP — load model, scaler, and UCI HAR data
# ══════════════════════════════════════════════════════════════════════════════
print()
_divider("═")
print("  SheSafe — Isolation Forest Model Evaluation")
print("  Two-Part Design: Real-Data Baseline  +  Exploratory Stress Test")
_divider("═")

for path, label in [(MODEL_PATH, "Model"), (SCALER_PATH, "Scaler")]:
    if not path.exists():
        print(f"\n[ERROR] {label} not found: {path}")
        sys.exit(1)

model  = joblib.load(MODEL_PATH)
scaler = joblib.load(SCALER_PATH)
print(f"\n  Model  : {MODEL_PATH.name}  [{type(model).__name__}]  ← UNCHANGED")
print(f"  Scaler : {SCALER_PATH.name}                            ← UNCHANGED")

print("\n📂 Loading UCI HAR test data …")
X_all    = pd.read_csv(UCI_TEST / "X_test.txt", sep=r'\s+', header=None)
y_labels = np.loadtxt(UCI_TEST / "y_test.txt", dtype=int)
print(f"   {len(X_all)} total windows, {X_all.shape[1]} features per window")

X_all_sel         = X_all.iloc[:, FEATURE_COL_IDX].copy()
X_all_sel.columns = FEATURE_NAMES

walking_mask = np.isin(y_labels, list(WALKING_IDS))
X_walk       = X_all_sel[walking_mask].values
y_walk_ids   = y_labels[walking_mask]

print("\n── Activity selection ────────────────────────────────────────────────")
for aid, aname in ACTIVITY_NAMES.items():
    n = int((y_walk_ids == aid).sum())
    print(f"   ✅ KEPT     {aname:<26}  n={n:>4}  → normal class")
for aid, aname in EXCLUDED_IDS.items():
    n = int((y_labels == aid).sum())
    print(f"   ❌ EXCLUDED {aname:<26}  n={n:>4}  (stationary — out of scope)")

RESULTS_DIR.mkdir(parents=True, exist_ok=True)

# ══════════════════════════════════════════════════════════════════════════════
# PART 1 — REAL-DATA BASELINE
# Normal class: UCI HAR walking windows (real recorded data)
# Anomaly class: NONE — no real anomaly recordings available
# Honest reportable metric: Specificity (false-alarm rate on real walking data)
# ══════════════════════════════════════════════════════════════════════════════
print()
_divider("═")
print("  PART 1 — REAL-DATA BASELINE  (primary results)")
print("  ─────────────────────────────────────────────────────────────────────")
print("  Data source : UCI HAR test set (real recordings)")
print("  Normal class: WALKING + WALKING_UPSTAIRS + WALKING_DOWNSTAIRS")
print("  Anomaly     : NONE — no real anomaly labels available in this project")
print("  Key metric  : Specificity (true negative rate on real walking windows)")
_divider("═")

X_walk_df    = pd.DataFrame(X_walk, columns=FEATURE_NAMES)
X_walk_sc    = scaler.transform(X_walk_df)
raw_walk     = model.predict(X_walk_sc)          # +1 inlier, -1 outlier
scores_walk  = model.decision_function(X_walk_sc)

# For walking windows: +1 (accepted as normal) → TN, -1 (flagged) → FP
n_walk       = len(X_walk)
n_accepted   = int((raw_walk == 1).sum())     # correctly kept normal
n_flagged    = int((raw_walk == -1).sum())    # false alarms on real walking
specificity_real = n_accepted / n_walk if n_walk > 0 else 0.0
false_alarm_rate = n_flagged  / n_walk if n_walk > 0 else 0.0

print(f"\n  Walking windows evaluated   : {n_walk}")
print(f"  Accepted as normal (TN)     : {n_accepted}  ({specificity_real:.1%})")
print(f"  Falsely flagged as anomaly  : {n_flagged}  ({false_alarm_rate:.1%})")
print()
print(f"  ┌───────────────────────────────────────────────────────────┐")
print(f"  │  PRIMARY REAL-DATA METRIC                                 │")
print(f"  │                                                           │")
print(f"  │  Specificity (TNR)  : {specificity_real*100:>6.2f} %                     │")
print(f"  │  False alarm rate   : {false_alarm_rate*100:>6.2f} % of real walking windows  │")
print(f"  │                                                           │")
print(f"  │  ⚠  No anomaly labels → Recall / Precision / AUC         │")
print(f"  │     cannot be computed from real data.                    │")
print(f"  │     Do NOT report those metrics as if they came from      │")
print(f"  │     real-world anomaly recordings.                        │")
print(f"  └───────────────────────────────────────────────────────────┘")

# Score distribution for the dissertation (shows IF threshold behaviour)
walk_anomaly_scores = -scores_walk    # flip: higher = more anomalous
print(f"\n  Distribution of anomaly scores (real walking windows):")
print(f"    min={walk_anomaly_scores.min():.4f}  "
      f"p25={np.percentile(walk_anomaly_scores, 25):.4f}  "
      f"median={np.median(walk_anomaly_scores):.4f}  "
      f"p75={np.percentile(walk_anomaly_scores, 75):.4f}  "
      f"max={walk_anomaly_scores.max():.4f}")
print(f"  (Lower score = more normal. Scores above threshold → flagged.)")

# Save a single-class confusion matrix (normal-only: TP on normal = TN, FP = false alarms)
fig, ax = plt.subplots(figsize=(5, 4))
y_true_walk = np.zeros(n_walk, dtype=int)           # all are truly normal
y_pred_walk = (raw_walk == -1).astype(int)          # 0 = accepted, 1 = flagged
_save_confusion_matrix(
    y_true_walk, y_pred_walk,
    labels=["walk\n(normal)", "flagged\n(false alarm)"],
    title=(
        "Part 1 — Real-Data Baseline: Normal-Class Performance\n"
        "Walking windows only (UCI HAR test) — No anomaly labels"
    ),
    filename="confusion_matrix_baseline.png",
)

# ══════════════════════════════════════════════════════════════════════════════
# PART 2 — EXPLORATORY SYNTHETIC STRESS TEST
# Anomaly class: statistically generated from walking distribution
# PURPOSE: verify model sensitivity; NOT a final accuracy measurement
# ══════════════════════════════════════════════════════════════════════════════
print()
_divider("═")
print("  PART 2 — EXPLORATORY SYNTHETIC STRESS TEST")
print("  ─────────────────────────────────────────────────────────────────────")
print("  ⚠  THESE ARE NOT REAL-WORLD ACCURACY RESULTS")
print("  ⚠  Anomaly windows are SYNTHETICALLY GENERATED.")
print("  ⚠  Do not cite Part 2 metrics as validated model performance.")
print("  ─────────────────────────────────────────────────────────────────────")
print("  Purpose : verify the model's directional sensitivity to extreme")
print("            feature deviations characteristic of dangerous events.")
print("  Method  : Gaussian perturbation of walking feature statistics")
print("            with physically motivated amplification per anomaly type.")
_divider("═")

print("\n── Generating synthetic anomaly windows ──────────────────────────────")
rng   = np.random.default_rng(42)
mu    = X_walk.mean(axis=0)
sigma = X_walk.std(axis=0)
sigma = np.where(sigma < 1e-8, 1e-8, sigma)

all_anomaly_X      = []
all_anomaly_labels = []

for atype, params in ANOMALY_TYPES.items():
    acc_m  = params["acc_mult"]
    jerk_m = params["jerk_mult"]
    gyro_m = params["gyro_mult"]

    samples = rng.normal(size=(N_ANOMALY_PER_TYPE, len(FEATURE_NAMES))) * sigma + mu

    if acc_m < 0:
        samples[:, ACC_MEAN_IDX] = (
            -np.abs(samples[:, ACC_MEAN_IDX]) * abs(acc_m)
        )
        samples[:, ACC_STD_IDX] *= (abs(acc_m) + 1.0)
    else:
        shift = acc_m * sigma[ACC_MEAN_IDX] * rng.uniform(
            2.5, 4.5, size=(N_ANOMALY_PER_TYPE, len(ACC_MEAN_IDX))
        )
        samples[:, ACC_MEAN_IDX] += shift
        samples[:, ACC_STD_IDX]  *= acc_m

    samples[:, JERK_IDX]      *= abs(jerk_m)
    samples[:, GYRO_MEAN_IDX] *= abs(gyro_m)
    samples[:, GYRO_STD_IDX]  *= abs(gyro_m)

    all_anomaly_X.append(samples)
    all_anomaly_labels.extend([atype] * N_ANOMALY_PER_TYPE)
    print(f"   {atype:<22}  n={N_ANOMALY_PER_TYPE}"
          f"  (acc×{acc_m:+.1f}, jerk×{jerk_m:.1f}, gyro×{gyro_m:.1f})")

X_anomaly        = np.vstack(all_anomaly_X)
anomaly_type_arr = np.array(all_anomaly_labels)
n_anomaly        = len(X_anomaly)
print(f"\n   Total synthetic windows : {n_anomaly}")

# Combine real walking (normal) + synthetic (anomaly)
X_stress = np.vstack([X_walk, X_anomaly])
y_stress = np.concatenate([
    np.zeros(len(X_walk), dtype=int),
    np.ones(n_anomaly,    dtype=int),
])
X_stress_df = pd.DataFrame(X_stress, columns=FEATURE_NAMES)
X_stress_sc = scaler.transform(X_stress_df)
raw_stress  = model.predict(X_stress_sc)
scores_stress = model.decision_function(X_stress_sc)
y_pred_stress = (raw_stress == -1).astype(int)
anomaly_scores_stress = -scores_stress

tn, fp, fn, tp = confusion_matrix(y_stress, y_pred_stress, labels=[0, 1]).ravel()
acc_s   = accuracy_score(y_stress, y_pred_stress)
prec_s  = tp / (tp + fp) if (tp + fp) > 0 else 0.0
rec_s   = tp / (tp + fn) if (tp + fn) > 0 else 0.0
f1_s    = 2 * prec_s * rec_s / (prec_s + rec_s) if (prec_s + rec_s) > 0 else 0.0
spec_s  = tn / (tn + fp) if (tn + fp) > 0 else 0.0

try:
    auc_s = roc_auc_score(y_stress, anomaly_scores_stress)
except Exception:
    auc_s = float("nan")

print(f"\n  Evaluation set: {len(X_walk)} real walking  +  {n_anomaly} synthetic anomaly")
print()
print(f"  ┌─────────────────────────────────────────────────────────────────┐")
print(f"  │  EXPLORATORY STRESS-TEST METRICS  (synthetic anomalies)        │")
print(f"  │  ⚠  Not real-world accuracy — for directional assessment only  │")
print(f"  ├─────────────────────────────────────────────────────────────────┤")
print(f"  │  Accuracy           : {acc_s*100:>6.2f} %                              │")
print(f"  │  Recall             : {rec_s*100:>6.2f} %  (detection of synthetic)   │")
print(f"  │  Precision          : {prec_s*100:>6.2f} %                              │")
print(f"  │  F1-score           : {f1_s*100:>6.2f} %                              │")
print(f"  │  Specificity        : {spec_s*100:>6.2f} %                              │")
print(f"  │  ROC-AUC            : {auc_s:>6.3f}                               │")
print(f"  └─────────────────────────────────────────────────────────────────┘")

print("\n── Detection rate per synthetic anomaly type ─────────────────────────")
y_pred_anom_seg = y_pred_stress[len(X_walk):]
for atype in ANOMALY_TYPES:
    mask = anomaly_type_arr == atype
    rate = y_pred_anom_seg[mask].mean()
    n    = int(mask.sum())
    print(f"   {atype:<22}  detected: {rate:>6.1%}   (n={n})")

print(f"""
  ─────────────────────────────────────────────────────────────────────
  Interpretation:
  High detection rates (close to 100 %) in Part 2 are expected because
  the synthetic anomalies are deliberately placed far outside the walking
  feature distribution. This confirms model sensitivity to large deviations
  but does NOT mean the model would detect real-world falls at this rate.

  For a validated anomaly recall figure, real labelled fall/incident data
  (e.g., SisFall, MobiAct) would be required. This is stated as a
  limitation in the dissertation.
  ─────────────────────────────────────────────────────────────────────""")

# Save Part 2 plots
_save_confusion_matrix(
    y_stress, y_pred_stress,
    labels=["normal\n(walk)", "anomaly\n(synthetic)"],
    title=(
        "Part 2 — Exploratory Stress Test (SYNTHETIC anomalies)\n"
        "⚠ Not real-world accuracy — directional sensitivity check only"
    ),
    filename="confusion_matrix_stress.png",
)

_save_roc(
    y_stress, anomaly_scores_stress, auc_s,
    title=(
        "ROC Curve — Part 2 Exploratory Stress Test\n"
        "Walking (real) vs Synthetic Anomalies  ⚠ Not validated accuracy"
    ),
    filename="roc_curve_stress.png",
)

# ══════════════════════════════════════════════════════════════════════════════
# PART 3 — THRESHOLD SENSITIVITY ANALYSIS  (real walking data only)
#
# How the Isolation Forest threshold works:
#   model.predict() flags a window when decision_function(x) < 0.0 (default).
#   Part 3 shifts that boundary by ±offset and measures the resulting
#   false alarm rate on the 1,387 REAL walking windows.
#
#   STRICTLY STRICTER threshold (offset < 0):
#     flag only when decision_function < negative_value
#     → fewer flags, lower false alarm rate, higher specificity
#     → trade-off: real anomalies closer to normal would be missed
#
#   LOOSELY STRICTER / LOOSER threshold (offset near ±0.02):
#     fine-grained steps around the default
#
#   STRICTLY LOOSER threshold (offset > 0):
#     flag when decision_function < positive_value
#     → more flags, higher false alarm rate, lower specificity
#     → trade-off: catches borderline anomalies, but more false alarms
#
# Data: real walking windows only (no synthetic). scores_walk already computed.
# No additional model or scaler calls needed.
# ══════════════════════════════════════════════════════════════════════════════
print()
_divider("═")
print("  PART 3 — THRESHOLD SENSITIVITY ANALYSIS  (real walking data only)")
print("  ─────────────────────────────────────────────────────────────────────")
print("  Data  : 1,387 real UCI HAR walking windows  (WALKING / UP / DOWN)")
print("  Score : Isolation Forest decision_function output")
print("  Rule  : flag window as anomaly when decision_function < threshold")
print("  Note  : NO synthetic data, NO anomaly labels — only FAR reported")
_divider("═")

# Threshold offsets relative to the default boundary of 0.0
# scores_walk = decision_function scores (higher = more normal)
# default rule: flag if scores_walk < 0.0
THRESHOLD_CONFIGS = [
    ("strictly_stricter",  -0.10),
    ("loosely_stricter",   -0.05),
    ("default_0.00",        0.00),
    ("loosely_looser",     +0.05),
    ("strictly_looser",    +0.10),
]

print(f"\n  Walking score range: "
      f"min={scores_walk.min():.4f}  "
      f"median={np.median(scores_walk):.4f}  "
      f"max={scores_walk.max():.4f}")
print(f"  (Scores below threshold → flagged as anomaly)\n")

threshold_rows = []

header = f"  {'Setting':<22}  {'Threshold':>10}  {'Flagged':>8}  {'Specificity':>12}  {'FalseAlarmRate':>15}"
_divider()
print(header)
_divider()

for name, offset in THRESHOLD_CONFIGS:
    flagged_mask = scores_walk < offset
    n_flagged_t  = int(flagged_mask.sum())
    specificity_t = 1.0 - n_flagged_t / n_walk
    far_t         = n_flagged_t / n_walk
    marker = "  ← default" if offset == 0.00 else ""
    print(f"  {name:<22}  {offset:>+10.2f}  {n_flagged_t:>8}  "
          f"{specificity_t*100:>10.2f} %  {far_t*100:>13.2f} %{marker}")
    threshold_rows.append({
        "threshold_name":    name,
        "threshold_value":   offset,
        "n_walking_windows": n_walk,
        "n_flagged":         n_flagged_t,
        "n_accepted":        n_walk - n_flagged_t,
        "specificity_pct":   round(specificity_t * 100, 2),
        "false_alarm_rate_pct": round(far_t * 100, 2),
    })

_divider()
print(f"""
  Interpretation:
  – Stricter thresholds flag fewer walking windows (lower false alarm rate)
    at the cost of potentially missing borderline real anomalies.
  – Looser thresholds catch more borderline events but increase false alarms
    on normal walking, which in the app would trigger unwanted alerts.
  – The default (0.00) matches the current model.predict() behaviour.
  – No recall/precision/AUC is reported here — there are no anomaly labels.
""")

# Save CSV
df_thresh = pd.DataFrame(threshold_rows)
csv_path  = RESULTS_DIR / "threshold_sensitivity_results.csv"
df_thresh.to_csv(csv_path, index=False)
print(f"   💾 Saved: {csv_path.name}")

# Save plot
fig, axes = plt.subplots(1, 2, figsize=(11, 4.5), sharey=False)

thresholds    = [r["threshold_value"]      for r in threshold_rows]
far_values    = [r["false_alarm_rate_pct"] for r in threshold_rows]
spec_values   = [r["specificity_pct"]      for r in threshold_rows]
flagged_vals  = [r["n_flagged"]            for r in threshold_rows]
bar_colors    = ["#2196F3" if t != 0.00 else "#F44336" for t in thresholds]
labels        = [r["threshold_name"]       for r in threshold_rows]

# Panel 1 — False alarm rate
axes[0].bar(labels, far_values, color=bar_colors, edgecolor="black", linewidth=0.6)
axes[0].axhline(far_values[2], color="#F44336", linestyle="--", linewidth=1.2,
                label=f"Default FAR = {far_values[2]:.2f}%")
axes[0].set_ylabel("False Alarm Rate (%)")
axes[0].set_title("False Alarm Rate vs Threshold\n(real walking windows only)", fontsize=10)
axes[0].legend(fontsize=8)
axes[0].tick_params(axis="x", rotation=30)
for i, v in enumerate(far_values):
    axes[0].text(i, v + 0.1, f"{v:.2f}%", ha="center", va="bottom", fontsize=8)

# Panel 2 — Specificity
axes[1].bar(labels, spec_values, color=bar_colors, edgecolor="black", linewidth=0.6)
axes[1].axhline(spec_values[2], color="#F44336", linestyle="--", linewidth=1.2,
                label=f"Default Spec = {spec_values[2]:.2f}%")
axes[1].set_ylabel("Specificity (%)")
axes[1].set_title("Specificity vs Threshold\n(real walking windows only)", fontsize=10)
axes[1].legend(fontsize=8)
axes[1].tick_params(axis="x", rotation=30)
axes[1].set_ylim(min(spec_values) - 2, 101)
for i, v in enumerate(spec_values):
    axes[1].text(i, v + 0.2, f"{v:.2f}%", ha="center", va="bottom", fontsize=8)

plt.suptitle(
    "Isolation Forest — Threshold Sensitivity Analysis\n"
    "Walking data only (1,387 real UCI HAR windows)  |  No anomaly labels",
    fontsize=10, fontweight="bold",
)
plt.tight_layout()
plot_path = RESULTS_DIR / "threshold_sensitivity_plot.png"
fig.savefig(plot_path, dpi=150)
plt.close(fig)
print(f"   📊 Saved: {plot_path.name}")

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
print()
_divider("═")
print("  SUMMARY")
_divider("═")
print(f"""
  PART 1 — Real-Data Baseline  (cite this in your dissertation)
    Normal-class specificity : {specificity_real:.1%}
    False alarm rate         : {false_alarm_rate:.1%}
    Data source              : UCI HAR test set (real recordings)
    Anomaly labels           : NONE available in project

  PART 2 — Exploratory Stress Test  (do NOT cite as final accuracy)
    Accuracy                 : {acc_s:.1%}
    Recall (synthetic)       : {rec_s:.1%}
    F1-score (synthetic)     : {f1_s:.1%}
    ROC-AUC (synthetic)      : {auc_s:.3f}
    Data source              : Synthetic (Gaussian perturbation of walking stats)

  PART 3 — Threshold Sensitivity (real walking data only)
    Threshold   FAR %     Specificity %""")

for r in threshold_rows:
    marker = "  ← default" if r["threshold_value"] == 0.00 else ""
    print(f"    {r['threshold_value']:>+6.2f}     "
          f"{r['false_alarm_rate_pct']:>5.2f}%     "
          f"{r['specificity_pct']:>6.2f}%{marker}")

print(f"""
  Model  : {MODEL_PATH.name}  ← UNCHANGED
  Scaler : {SCALER_PATH.name}  ← UNCHANGED
  app.py and all runtime logic : UNCHANGED

  Output files saved to: {RESULTS_DIR}/
    confusion_matrix_baseline.png
    confusion_matrix_stress.png
    roc_curve_stress.png
    threshold_sensitivity_results.csv
    threshold_sensitivity_plot.png
""")
_divider("═")
