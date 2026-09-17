"""Pure scoring and item-analysis logic, independent of image processing."""

import math
import statistics

VALID_ANSWERS = frozenset("ABCDE")
UNRESOLVED = frozenset(("BLANK", "MULTIPLE"))


def validate_answer_key(answer_key, question_count=50):
    missing = [q for q in range(1, question_count + 1) if q not in answer_key]
    invalid = {
        q: answer_key.get(q)
        for q in range(1, question_count + 1)
        if q in answer_key and answer_key[q] not in VALID_ANSWERS
    }
    return {"valid": not missing and not invalid, "missing": missing, "invalid": invalid}


def score_student(answers, answer_key, question_count=50):
    validation = validate_answer_key(answer_key, question_count)
    if not validation["valid"]:
        raise ValueError(f"answer key is unresolved: {validation}")

    correct = incorrect = blank = multiple = 0
    missed = []
    for q in range(1, question_count + 1):
        given = answers.get(q, "BLANK")
        key = answer_key[q]
        if given == key:
            correct += 1
        elif given == "BLANK":
            blank += 1
            missed.append(q)
        elif given == "MULTIPLE":
            multiple += 1
            missed.append(q)
        else:
            incorrect += 1
            missed.append(q)
    return {
        "correct": correct,
        "incorrect": incorrect,
        "blank": blank,
        "multiple": multiple,
        "percentage": round(correct / question_count * 100, 1),
        "missed_questions": missed,
    }


def _point_biserial(item_scores, total_scores):
    n = len(item_scores)
    if n < 3 or len(set(item_scores)) < 2:
        return None
    p = sum(item_scores) / n
    q = 1 - p
    if not p or not q:
        return None
    corrected_totals = [total - item for total, item in zip(total_scores, item_scores)]
    if len(set(corrected_totals)) < 2:
        return None
    mean_correct = statistics.mean(t for t, item in zip(corrected_totals, item_scores) if item)
    mean_wrong = statistics.mean(t for t, item in zip(corrected_totals, item_scores) if not item)
    sd = statistics.stdev(corrected_totals)
    return round(((mean_correct - mean_wrong) / sd) * math.sqrt(p * q), 3) if sd else None


def item_analysis(all_answers, answer_key, question_count=50, flag_thresholds=(25, 40, 50)):
    validation = validate_answer_key(answer_key, question_count)
    if not validation["valid"]:
        raise ValueError(f"answer key is unresolved: {validation}")
    n = len(all_answers)
    totals = [sum(ans.get(q) == answer_key[q] for q in range(1, question_count + 1)) for ans in all_answers]
    analysis = {}
    for q in range(1, question_count + 1):
        counts = {choice: 0 for choice in (*sorted(VALID_ANSWERS), *sorted(UNRESOLVED))}
        for ans in all_answers:
            given = ans.get(q, "BLANK")
            counts[given] = counts.get(given, 0) + 1
        key = answer_key[q]
        n_correct = counts.get(key, 0)
        pct_correct = round(n_correct / n * 100, 1) if n else 0.0
        wrong = {k: v for k, v in counts.items() if k in VALID_ANSWERS and k != key and v > 0}
        item_scores = [int(ans.get(q) == key) for ans in all_answers]
        group_n = max(1, round(n * 0.27)) if n else 0
        ranked = sorted(zip(totals, item_scores), key=lambda pair: pair[0])
        discrimination = None
        if n >= 10:
            lower = ranked[:group_n]
            upper = ranked[-group_n:]
            discrimination = round(
                sum(item for _, item in upper) / group_n - sum(item for _, item in lower) / group_n,
                3,
            )
        missed_pct = 100 - pct_correct
        analysis[q] = {
            "correct_answer": key,
            "n_correct": n_correct,
            "pct_correct": pct_correct,
            "difficulty": round(pct_correct / 100, 3),
            "point_biserial": _point_biserial(item_scores, totals),
            "upper_lower_discrimination": discrimination,
            "distribution": {
                k: {"count": v, "pct": round(v / n * 100, 1) if n else 0.0}
                for k, v in counts.items()
            },
            "most_common_wrong": max(wrong, key=wrong.get) if wrong else None,
            "flags": {f"missed_{threshold}": missed_pct > threshold for threshold in flag_thresholds},
        }
    return analysis


def class_statistics(scores, item_rows, question_count=50):
    raw = [score["correct"] for score in scores.values()]
    result = {
        "student_count": len(raw),
        "mean": round(statistics.mean(raw), 2) if raw else None,
        "median": round(statistics.median(raw), 2) if raw else None,
        "standard_deviation": round(statistics.stdev(raw), 2) if len(raw) > 1 else None,
        "minimum": min(raw) if raw else None,
        "maximum": max(raw) if raw else None,
        "kr20": None,
    }
    if question_count > 1 and len(raw) > 1 and statistics.variance(raw) > 0:
        pq_sum = sum((row["difficulty"] * (1 - row["difficulty"])) for row in item_rows.values())
        result["kr20"] = round(
            question_count / (question_count - 1) * (1 - pq_sum / statistics.variance(raw)), 3
        )
    return result
