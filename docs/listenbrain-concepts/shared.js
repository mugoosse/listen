document.documentElement.classList.add("js");

document.querySelectorAll("[data-context-toggle]").forEach((button) => {
  button.addEventListener("click", () => {
    const value = button.dataset.contextToggle;
    document.body.dataset.context = value;
    document.querySelectorAll("[data-context-toggle]").forEach((candidate) => {
      candidate.setAttribute("aria-pressed", String(candidate === button));
    });
  });
});

document.querySelectorAll("[data-question]").forEach((button) => {
  button.addEventListener("click", () => {
    const target = document.querySelector("[data-answer]");
    if (!target) return;
    target.textContent = button.dataset.answer || "";
    document.querySelectorAll("[data-question]").forEach((candidate) => {
      candidate.setAttribute("aria-pressed", String(candidate === button));
    });
  });
});

document.querySelectorAll("[data-control]").forEach((button) => {
  button.addEventListener("click", () => {
    const status = document.querySelector("[data-control-status]");
    if (!status) return;
    status.textContent = button.dataset.result || "Updated.";
    status.hidden = false;
  });
});

document.querySelectorAll("[data-year]").forEach((node) => {
  node.textContent = String(new Date().getFullYear());
});
