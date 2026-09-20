/**
 * ════════════════════════════════════════════════════════════════
 *  선택 사항: Apps Script 배치 처리 (첫 화면 요청 3~4건 → 1건)
 * ════════════════════════════════════════════════════════════════
 *
 * [왜 필요한가]
 *   Apps Script 웹앱은 호출 1건당 302 리다이렉트(왕복 2회) + 스크립트
 *   기동/실행 시간이 붙는다. 실제 데이터 양보다 "호출 횟수"가 체감 속도를
 *   좌우한다. 첫 화면에 필요한 4가지 조회를 한 번에 처리하면 그만큼 빨라진다.
 *
 * [안 붙여도 된다]
 *   index.html 은 이 기능이 없으면 알아서 개별 요청으로 동작한다.
 *   붙이면 다음 접속부터 자동으로 감지해서 배치 모드로 전환된다.
 *   (감지 결과는 브라우저 localStorage 의 sch_batch 키에 기록된다)
 *
 * [설치 방법 - 2분]
 *   1. Apps Script 편집기에서 기존 함수 이름을  doPost  →  doPostOne  으로 변경
 *   2. 아래 doPost 함수를 그대로 붙여넣기
 *   3. 배포 → 배포 관리 → 편집(연필) → 버전: 새 버전 → 배포
 *      ※ GAS_URL 은 그대로 유지된다 (새 URL 이 발급되지 않음)
 *
 * 기존 코드를 전혀 읽거나 수정할 필요가 없다. 감싸기만 한다.
 */

function doPost(e) {
  var req = {};
  try { req = JSON.parse(e.postData.contents); } catch (err) {}

  // 배치가 아니면 기존 로직 그대로
  if (!req || req.action !== 'batch') return doPostOne(e);

  var requests = req.requests || [];
  if (requests.length > 20) {                       // 과도한 요청 방지
    return jsonOut_({ ok: false, error: 'batch 요청이 너무 많습니다' });
  }

  var results = requests.map(function (r) {
    try {
      var out = doPostOne({ postData: { contents: JSON.stringify(r) } });
      return JSON.parse(out.getContent());
    } catch (err) {
      return { ok: false, error: String(err) };
    }
  });

  return jsonOut_({ ok: true, results: results });
}

function jsonOut_(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
