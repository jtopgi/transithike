const pad = (number) => String(number).padStart(2, "0")

const inputValue = (date) =>
  `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`

// An hour from now on the visitor's clock, rounded up to the next quarter hour.
function defaultArrival() {
  const date = new Date(Date.now() + 60 * 60 * 1000)
  date.setMinutes(Math.ceil(date.getMinutes() / 15) * 15, 0, 0)
  return inputValue(date)
}

function setBusy(form, busy) {
  const button = form.querySelector("[data-search-submit]")
  const label = button?.querySelector("[data-search-label]")
  if (!button || !label) return

  label.dataset.idleText ??= label.textContent
  label.textContent = busy ? "Searching…" : label.dataset.idleText
  button.disabled = busy
  button.setAttribute("aria-busy", String(busy))
  button.querySelector(".spinner-border")?.classList.toggle("d-none", !busy)
}

const searchForms = () => document.querySelectorAll("form[data-search-form]")

document.addEventListener("DOMContentLoaded", () => {
  searchForms().forEach((form) => {
    const arrival = form.querySelector('input[type="datetime-local"]')
    if (arrival && !arrival.value) arrival.value = defaultArrival()
    form.addEventListener("submit", () => setBusy(form, true))
  })
})

// Going back restores pages from the back/forward cache with the button still busy.
window.addEventListener("pageshow", (event) => {
  if (event.persisted) searchForms().forEach((form) => setBusy(form, false))
})
