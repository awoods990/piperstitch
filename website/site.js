/* PiperStitch — minimal site behaviour. No dependencies, no tracking. */
(function () {
  "use strict";

  // Mobile navigation
  var toggle = document.getElementById("navToggle");
  var nav = document.getElementById("siteNav");
  if (toggle && nav) {
    toggle.addEventListener("click", function () {
      var open = nav.classList.toggle("open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
    nav.addEventListener("click", function (e) {
      if (e.target.tagName === "A") {
        nav.classList.remove("open");
        toggle.setAttribute("aria-expanded", "false");
      }
    });
  }

  // Current year in the footer
  var year = document.getElementById("year");
  if (year) { year.textContent = new Date().getFullYear(); }

  // Registration: surface server-side validation errors sent back as ?err=
  var box = document.getElementById("formError");
  if (box) {
    var messages = {
      name:    "Please give both your first and last name.",
      email:   "That email address doesn't look right. Please check it.",
      terms:   "You need to accept the Terms of Use and Privacy Policy to download PiperStitch.",
      billing: "Please confirm you understand the trial and subscription terms.",
      age:     "You need to confirm you are at least 18 years old."
    };
    var code = new URLSearchParams(window.location.search).get("err");
    if (code && messages[code]) {
      document.getElementById("formErrorText").textContent = messages[code];
      box.hidden = false;
      var focusMap = {
        name: "first_name", email: "email",
        terms: "accept_terms", billing: "accept_billing", age: "accept_age"
      };
      var el = document.getElementById(focusMap[code]);
      if (el) { el.focus({ preventScroll: true }); }
    }
  }

  // FAQ: only one answer open at a time
  var faq = document.querySelectorAll(".faq details");
  Array.prototype.forEach.call(faq, function (d) {
    d.addEventListener("toggle", function () {
      if (!d.open) { return; }
      Array.prototype.forEach.call(faq, function (o) {
        if (o !== d) { o.open = false; }
      });
    });
  });
})();
