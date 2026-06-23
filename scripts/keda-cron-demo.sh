#!/usr/bin/env bash
# =============================================================================
# KEDA cron 데모 — 시간 주입 + 적용 (docs/06 "4) 시간 기반 트리거")
# -----------------------------------------------------------------------------
# manifests/keda-cron.yaml 의 cron start/end 를 "현재 시각 +N분"으로 편집한 뒤
# kubectl apply 까지만 수행합니다. (관찰은 docs/06 의 안내대로 수동으로 진행)
#
# 사용법(Azure Cloud Shell, bash, 저장소 루트에서):
#   bash scripts/keda-cron-demo.sh                 # +2분 시작 / +5분 종료로 편집 후 적용
#   START_OFFSET=1 END_OFFSET=4 bash scripts/keda-cron-demo.sh
#
# 환경변수(기본값):
#   START_OFFSET=2   지금부터 확장 시작까지(분)
#   END_OFFSET=5     지금부터 시간대 종료까지(분)  (START_OFFSET 보다 커야 함)
#   TZ_NAME=Asia/Seoul   cron 타임존(IANA)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

START_OFFSET="${START_OFFSET:-2}"
END_OFFSET="${END_OFFSET:-5}"
TZ_NAME="${TZ_NAME:-Asia/Seoul}"
MANIFEST="manifests/keda-cron.yaml"

[ -f "$MANIFEST" ] || { echo "manifest 없음: $MANIFEST (저장소 루트에서 실행)"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl 미설치"; exit 1; }
if [ "$END_OFFSET" -le "$START_OFFSET" ]; then
  echo "END_OFFSET($END_OFFSET) 는 START_OFFSET($START_OFFSET) 보다 커야 합니다."; exit 1
fi

# 현재 시각 기준 cron(분 시) 계산
start_min="$(TZ="$TZ_NAME" date -d "+${START_OFFSET} minutes" +%-M)"
start_hr="$(TZ="$TZ_NAME" date -d "+${START_OFFSET} minutes" +%-H)"
end_min="$(TZ="$TZ_NAME" date -d "+${END_OFFSET} minutes" +%-M)"
end_hr="$(TZ="$TZ_NAME" date -d "+${END_OFFSET} minutes" +%-H)"
START_CRON="${start_min} ${start_hr} * * *"
END_CRON="${end_min} ${end_hr} * * *"

# manifest 의 start/end 를 in-place 로 편집(+2분/+5분)
sed -i -E \
  -e "s|^([[:space:]]*start:).*|\1 \"${START_CRON}\"|" \
  -e "s|^([[:space:]]*end:).*|\1 \"${END_CRON}\"|" \
  "$MANIFEST"

echo "manifest 편집 완료 (TZ=$TZ_NAME)"
echo "  start: \"$START_CRON\"  (+${START_OFFSET}분)"
echo "  end:   \"$END_CRON\"  (+${END_OFFSET}분)"
echo

kubectl apply -f "$MANIFEST"
echo
echo "적용 완료. 이제 docs/06 안내대로 확장/축소를 관찰하세요:"
echo "  kubectl get hpa keda-hpa-store-front-cron -n pets"
echo "  kubectl get pods -n pets -l app=store-front"
