// Starting-point autocomplete (an ARIA combobox), "Use my location", and the
// busy state while a search runs.
const DEBOUNCE_MS = 250
const MIN_QUERY_LENGTH = 3

class PlaceSearch {
  constructor(form) {
    this.form = form
    this.input = form.querySelector('[role="combobox"]')
    this.list = form.querySelector('[role="listbox"]')
    this.latitude = form.querySelector('input[name="lat"]')
    this.longitude = form.querySelector('input[name="lon"]')
    this.status = form.querySelector("[data-search-status]")
    this.places = []
    this.active = -1
    this.timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone
    // Typed places near the visitor come first.
    const zone = form.querySelector('input[name="tz"]')
    if (zone) zone.value = this.timeZone
    // Unless a day was asked for, offer whichever weekend day comes next here.
    if (!new URLSearchParams(window.location.search).has("day")) {
      const day = form.querySelector(`input[name="day"][value="${upcomingDay(new Date())}"]`)
      if (day) day.checked = true
    }

    this.input.addEventListener("input", () => this.onInput())
    this.input.addEventListener("keydown", (event) => this.onKeydown(event))
    this.input.addEventListener("blur", () => this.close())
    form.addEventListener("submit", () => setBusy(form, true))

    const locate = form.querySelector("[data-use-location]")
    if (locate && "geolocation" in navigator) {
      locate.hidden = false
      locate.addEventListener("click", () => this.useLocation())
    }
  }

  onInput() {
    // Typing replaces any place chosen earlier, so its coordinates no longer apply.
    this.setCoordinates(null)
    clearTimeout(this.timer)
    const query = this.input.value.trim()
    if (query.length < MIN_QUERY_LENGTH) return this.close()
    this.timer = setTimeout(() => this.suggest(query), DEBOUNCE_MS)
  }

  async suggest(query) {
    this.request?.abort()
    this.request = new AbortController()
    try {
      const params = new URLSearchParams({ q: query, tz: this.timeZone })
      const response = await fetch(`/places?${params}`, {
        signal: this.request.signal, headers: { Accept: "application/json" }
      })
      this.render(response.ok ? await response.json() : [])
    } catch (error) {
      if (error.name !== "AbortError") this.close()
    }
  }

  render(places) {
    this.places = places
    this.active = -1
    this.list.replaceChildren(...places.map((place, index) => {
      const option = document.createElement("li")
      option.id = `origin-option-${index}`
      option.className = "place-suggestion"
      option.setAttribute("role", "option")
      option.setAttribute("aria-selected", "false")
      option.textContent = place.name
      // Choose on mousedown so the input's blur doesn't close the list first.
      option.addEventListener("mousedown", (event) => {
        event.preventDefault()
        this.choose(index)
      })
      return option
    }))
    this.setOpen(places.length > 0)
  }

  onKeydown(event) {
    if (this.list.hidden) return
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.highlight(event.key === "ArrowDown" ? 1 : -1)
    } else if (event.key === "Enter" && this.active >= 0) {
      event.preventDefault()
      this.choose(this.active)
    } else if (event.key === "Escape") {
      this.close()
    }
  }

  highlight(step) {
    const count = this.places.length
    this.active = (this.active + step + count) % count
    this.list.querySelectorAll('[role="option"]').forEach((option, index) => {
      option.setAttribute("aria-selected", String(index === this.active))
      if (index === this.active) option.scrollIntoView({ block: "nearest" })
    })
    this.input.setAttribute("aria-activedescendant", `origin-option-${this.active}`)
  }

  choose(index) {
    const place = this.places[index]
    this.input.value = place.name
    this.setCoordinates(place)
    this.close()
    this.form.requestSubmit()
  }

  useLocation() {
    this.status.textContent = "Finding your location…"
    navigator.geolocation.getCurrentPosition(
      ({ coords }) => {
        this.status.textContent = ""
        this.input.value = this.form.dataset.currentLocation
        this.setCoordinates({ lat: coords.latitude.toFixed(5), lon: coords.longitude.toFixed(5) })
        this.form.requestSubmit()
      },
      () => { this.status.textContent = "We couldn't get your location. Type a starting point instead." },
      { timeout: 10000, maximumAge: 10 * 60 * 1000 }
    )
  }

  setCoordinates(place) {
    // Disabled fields aren't submitted, which keeps typed searches' URLs clean.
    this.latitude.value = place ? place.lat : ""
    this.longitude.value = place ? place.lon : ""
    this.latitude.disabled = this.longitude.disabled = !place
  }

  setOpen(open) {
    this.list.hidden = !open
    this.input.setAttribute("aria-expanded", String(open))
    if (!open) this.input.removeAttribute("aria-activedescendant")
  }

  close() {
    this.setOpen(false)
  }
}

// Like the search, Saturday or Sunday, whichever comes first; from 10 AM on, it's too late to set out that day.
function upcomingDay(now) {
  const weekday = now.getDay()
  const late = now.getHours() >= 10
  if (weekday === 6) return late ? "sunday" : "saturday"
  if (weekday === 0 && !late) return "sunday"
  return "saturday"
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

const searchForms = () => document.querySelectorAll("form[data-place-search]")

document.addEventListener("DOMContentLoaded", () => searchForms().forEach((form) => new PlaceSearch(form)))

// Going back restores pages from the back/forward cache with the button still busy.
window.addEventListener("pageshow", (event) => {
  if (event.persisted) searchForms().forEach((form) => setBusy(form, false))
})
