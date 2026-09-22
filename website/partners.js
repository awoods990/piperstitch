// Partner page calculator: the program's arithmetic, nothing more.
// $24/mo core, $24/mo Proofs, rate on the gross, 24-month term,
// $15 bounty on signups in the first 120 days (four months of signups).
(function () {
  var CORE = 24, PROOFS = 24, MONTHS = 24, BOUNTY = 15, WINDOW_MONTHS = 4;
  var ref = document.getElementById('calcRef'), proofs = document.getElementById('calcProofs');
  if (!ref || !proofs) return;
  var money = function (n, cents) { return '$' + (cents ? n.toFixed(2) : Math.round(n).toLocaleString('en-US')); };
  function update() {
    var n = +ref.value, p = +proofs.value / 100;
    var rate = +(document.querySelector('input[name=calcRate]:checked') || {}).value / 100 || .3;
    var perMonth = (CORE + PROOFS * p) * rate;            // per referral, blended for Proofs
    document.getElementById('calcRefOut').textContent = n;
    document.getElementById('calcProofsOut').textContent = Math.round(p * 100) + '%';
    document.getElementById('calcRateOut').textContent = Math.round(rate * 100) + '%';
    document.getElementById('calcPerMonth').textContent = money(perMonth, true);
    document.getElementById('calcPerRef').textContent = money(perMonth * MONTHS + (p ? 0 : 0), true);
    document.getElementById('calcBounty').textContent = money(n * WINDOW_MONTHS * BOUNTY);
    document.getElementById('calcMonth12').textContent = money(perMonth * n * 12);
    document.getElementById('calcSteady').textContent = money(perMonth * n * MONTHS);
  }
  [ref, proofs].forEach(function (el) { el.addEventListener('input', update); });
  document.querySelectorAll('input[name=calcRate]').forEach(function (el) { el.addEventListener('change', update); });
  update();
})();
