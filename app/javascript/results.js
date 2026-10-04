// Results page: streams hikes in as they are found, most scenic first, then filters and previews them.
import { drawMap } from "./map_preview"

// The sliders narrow hikes down by round trip and length, so they're only ever
// ranked most scenic first, ties keeping the recommended order.
const byScore = (a, b) => b.dataset.score - a.dataset.score || a.dataset.travel - b.dataset.travel
const mostScenic = (a, b) => b.dataset.scenic - a.dataset.scenic || byScore(a, b)
// A slider at its end filters nothing: any round trip, and any length from the shortest to the longest.
const miles = (value) => `${Number(value)} mi`
const MODE_ICONS = {
  BUS: "🚌", COACH: "🚍", TRAM: "🚊", SUBWAY: "🚇", FERRY: "⛴️",
  FUNICULAR: "🚞", AERIAL_LIFT: "🚡", AREAL_LIFT: "🚡", CABLE_CAR: "🚡"
}
// Transitous's METRO is an old name for suburban trains.
const modeIcon = (mode) => MODE_ICONS[mode] || (/RAIL|SUBURBAN|LONG_DISTANCE|METRO/.test(mode) ? "🚆" : "🚏")
const rideMinutes = (trip) => Math.round((new Date(trip.arrival) - new Date(trip.departure)) / 60000)
// Like the server's labels: "4 h 35 min", "2 h", or "50 min", and whole hours from four hours on for time there.
const duration = (minutes) => {
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  return [hours > 0 && `${hours} h`, (rest > 0 || hours === 0) && `${rest} min`].filter(Boolean).join(" ")
}
const stayLabel = (minutes) => minutes >= 240 ? `${Math.floor(minutes / 60)} h` : duration(minutes)

// On phones, the results page's search box stays closed behind "Change search",
// so the hikes come first. Without the page's script, it stays open.
class SearchToggle {
  constructor(button) {
    this.button = button
    this.panel = document.getElementById(button.getAttribute("aria-controls"))
    button.hidden = false
    this.set(false)
    button.addEventListener("click", () => {
      this.set(!this.open)
      if (this.open) this.panel.querySelector('[role="combobox"]')?.focus()
    })
  }

  set(open) {
    this.open = open
    this.button.setAttribute("aria-expanded", String(open))
    this.panel.classList.toggle("is-collapsed", !open)
  }
}

class Results {
  constructor(page, search) {
    this.page = page
    this.search = search
    this.list = page.querySelector("[data-trails]")
    this.toolbar = page.querySelector("[data-results-toolbar]")
    this.progress = page.querySelector("[data-progress]")
    this.found = 0
    this.done = false
    // Trips are looked up two cards at a time, which the transit planner shares between visitors.
    this.tripQueues = [Promise.resolve(), Promise.resolve()]
    this.tripTurn = 0
    // Photos two at a time, so a page never keeps more of the server busy looking for them.
    this.photoQueues = [Promise.resolve(), Promise.resolve()]
    this.photoTurn = 0
    this.previews = new IntersectionObserver((entries) => this.visible(entries, (card) => this.preview(card)),
      { rootMargin: "200px" })
    this.trips = new IntersectionObserver((entries) => this.visible(entries, (card) => this.queueTrip(card)),
      { rootMargin: "100px" })
    this.maxTrip = this.toolbar.querySelector("[data-max-trip]")
    this.shortest = this.toolbar.querySelector("[data-length-min]")
    this.longest = this.toolbar.querySelector("[data-length-max]")
    this.toolbar.addEventListener("change", () => this.update())
    // Sliders filter as they move, and their handles can't pass each other.
    this.toolbar.addEventListener("input", ({ target }) => {
      if (target === this.shortest && Number(this.shortest.value) > Number(this.longest.value)) this.longest.value = this.shortest.value
      if (target === this.longest && Number(this.longest.value) < Number(this.shortest.value)) this.shortest.value = this.longest.value
      this.update()
    })
  }

  stream() {
    const events = new EventSource(this.page.dataset.streamUrl)
    const on = (name, handler) => events.addEventListener(name, (event) => handler(JSON.parse(event.data)))
    on("place", (place) => this.place(place))
    on("checking", ({ count, station }) => this.status(this.found
      ? `Found ${this.found} so far. Checking trains from ${station} to ${count} more hikes…`
      : `Checking trains from ${station} to ${count} hikes and back…`))
    on("trails", ({ html }) => this.add(html))
    on("update", ({ trails }) => this.refresh(trails))
    on("done", (summary) => { events.close(); this.finish(summary) })
    on("failure", ({ message }) => { events.close(); this.fail(message) })
    events.addEventListener("error", () => {
      // EventSource reconnects on its own, which would start the search over.
      events.close()
      if (!this.done) this.fail("The connection was lost. Please search again.")
    })
  }

  place({ heading, departure, time_zone: timeZone, stations }) {
    const page = this.page.ownerDocument
    page.querySelector("[data-heading]").textContent = heading
    page.querySelector("[data-departure]").textContent = departure
    // The stations trips leave from, rendered by the server, which escapes them.
    const line = page.querySelector("[data-stations]")
    line.innerHTML = stations || ""
    line.hidden = !stations
    document.title = `${heading} · TransitHike`
    this.timeZone = timeZone
  }

  status(text) {
    this.progress.querySelector("[data-progress-text]").textContent = text
  }

  add(html) {
    const template = document.createElement("template")
    template.innerHTML = html
    this.list.querySelectorAll("[data-skeleton]").forEach((skeleton) => skeleton.remove())
    const cards = [...template.content.querySelectorAll("[data-trail]")]
    cards.forEach((card) => {
      // A hike already shown is replaced when another station gets there sooner.
      const shown = this.list.querySelector(`[data-osm-id="${Number(card.dataset.osmId)}"]`)
      if (shown) {
        this.previews.unobserve(shown)
        this.trips.unobserve(shown)
        shown.replaceWith(card)
        if (this.done) this.trips.observe(card)
      } else {
        this.list.append(card)
        this.found += 1
      }
      this.previews.observe(card)
    })
    this.toolbar.hidden = false
    this.update()
  }

  // Highlights and terrain rank the hikes once every batch is checked.
  refresh(trails) {
    trails.forEach(({ id, score, scenic, climb, chips }) => {
      const card = this.list.querySelector(`[data-osm-id="${Number(id)}"]`)
      if (!card) return

      Object.assign(card.dataset, { score, scenic })
      card.querySelector("[data-chips]").innerHTML = chips
      if (climb) {
        card.querySelector("[data-climb]").textContent = climb
        card.querySelector("[data-climb-stat]").hidden = false
      }
    })
    this.update()
  }

  finish({ count, notices }) {
    this.done = true
    this.progress.hidden = true
    this.list.querySelectorAll("[data-skeleton]").forEach((skeleton) => skeleton.remove())
    this.page.querySelector("[data-empty]").hidden = count > 0
    // Without hikes, the next step is another search.
    if (count === 0) this.search?.set(true)
    this.notify(notices)
    // Trips are looked up once the search is done, so they don't hold it up.
    this.list.querySelectorAll("[data-trail]").forEach((card) => this.trips.observe(card))
  }

  fail(message) {
    this.done = true
    this.progress.hidden = true
    this.list.querySelectorAll("[data-skeleton]").forEach((skeleton) => skeleton.remove())
    if (this.found > 0) {
      this.notify([message])
    } else {
      const alert = this.page.querySelector("[data-failure]")
      alert.textContent = message
      alert.hidden = false
      this.search?.set(true)
    }
  }

  notify(messages) {
    const box = this.page.querySelector("[data-notices]")
    box.replaceChildren(...messages.map((message) => Object.assign(document.createElement("p"), {
      className: "mb-0", textContent: message
    })))
    box.hidden = messages.length === 0
  }

  // The round-trip slider spans the hikes found, from the quickest to the longest,
  // so every step shows some hikes. Its right end still means any round trip.
  fitTrips() {
    const minutes = [...this.list.querySelectorAll("[data-trail]")].map((card) => Number(card.dataset.travel) / 60)
    if (minutes.length === 0) return

    const step = Number(this.maxTrip.step)
    const quickest = Math.ceil(Math.min(...minutes) / step) * step
    const longest = Math.max(Math.ceil(Math.max(...minutes) / step) * step, quickest + step)
    const any = this.maxTrip.value === this.maxTrip.max
    this.maxTrip.min = quickest
    this.maxTrip.max = longest
    if (any) this.maxTrip.value = longest
  }

  update() {
    this.fitTrips()
    const anyTrip = this.maxTrip.value === this.maxTrip.max
    const maxTrip = anyTrip ? Infinity : Number(this.maxTrip.value) * 60
    const min = this.shortest.value === this.shortest.min ? 0 : Number(this.shortest.value)
    const max = this.longest.value === this.longest.max ? Infinity : Number(this.longest.value)
    this.toolbar.querySelector("[data-max-trip-label]").textContent = anyTrip ? "any" : `up to ${duration(Number(this.maxTrip.value))}`
    this.toolbar.querySelector("[data-length-label]").textContent = min === 0 && max === Infinity ? "any"
      : max === Infinity ? `${miles(min)} or more` : min === 0 ? `up to ${miles(max)}` : `${Number(min)}–${miles(max)}`
    const range = this.toolbar.querySelector("[data-length-range]")
    const percent = (input) => `${(input.value - input.min) / (input.max - input.min) * 100}%`
    this.maxTrip.style.setProperty("--fill", percent(this.maxTrip))
    range.style.setProperty("--low", percent(this.shortest))
    range.style.setProperty("--high", percent(this.longest))
    const cards = [...this.list.querySelectorAll("[data-trail]")]
    cards.sort(mostScenic).forEach((card) => {
      const length = Number(card.dataset.length)
      card.hidden = !(length >= min && length <= max && Number(card.dataset.travel) <= maxTrip)
      this.list.append(card)
    })
    this.count()
  }

  count() {
    const cards = [...this.list.querySelectorAll("[data-trail]")]
    const shown = cards.filter((card) => !card.hidden).length
    this.toolbar.querySelector("[data-results-count]").textContent = `Showing ${shown} of ${cards.length} hikes`
    this.page.querySelector("[data-no-matches]").hidden = shown > 0 || cards.length === 0
    // Once the search is done, taking off the page every hike it found leaves none.
    if (this.done && cards.length === 0) {
      this.toolbar.hidden = true
      this.page.querySelector("[data-empty]").hidden = false
      this.search?.set(true)
    }
  }

  visible(entries, show) {
    entries.filter((entry) => entry.isIntersecting).forEach(({ target }) => show(target))
  }

  preview(card) {
    this.previews.unobserve(card)
    const map = drawMap(card.querySelector(".trail-map"))
    const lane = this.photoTurn++ % this.photoQueues.length
    this.photoQueues[lane] = this.photoQueues[lane].then(() => showPhotos(card, map)).catch(() => {})
  }

  queueTrip(card) {
    this.trips.unobserve(card)
    const lane = this.tripTurn++ % this.tripQueues.length
    this.tripQueues[lane] = this.tripQueues[lane].then(() => this.showTrip(card)).catch(() => {})
  }

  async showTrip(card) {
    const box = card.querySelector("[data-trip-url]")
    const response = await fetch(box.dataset.tripUrl, { headers: { Accept: "application/json" } })
    if (!response.ok) return

    const { there, back, last, after_sunset: dusk, same_way: sameWay, location } = await response.json()
    // The planned trips are exact to the minute, unlike the search's estimates:
    // hikes they leave too little time for, by sunset or before the last trip back, aren't shown.
    if (there && !this.timeToHike(card, there, last)) return this.drop(card)

    if (location) {
      const line = card.querySelector("[data-location]")
      line.querySelector("[data-location-text]").textContent = location
      line.classList.remove("invisible")
    }
    // The search's travel times include waiting for the train.
    if (there && back) this.showTravel(card, rideMinutes(there), rideMinutes(back))
    if (last) this.showLast(card, last, there)
    // The first trip back after the hike, then the first after sunset, for hiking until then, or
    // where the last trip back is the deadline, that one.
    const from = card.dataset.plan === "through" ? " from the end" : ""
    const dark = last && this.sunsetFirst(card, last) && dusk
    const latest = dark ? dusk : last
    const latestToo = latest && back && latest.departure !== back.departure
    const latestLabel = dark && dusk.departure !== last.departure ? "After sunset" : "Last back"
    const lines = [["There", there, "arrive"], [latestToo ? `First back${from}` : `Back${from}`, back, "home"],
      [`${latestLabel}${from}`, latestToo ? latest : null, "home"]]
      .filter(([, trip]) => trip)
      .map(([label, trip, end]) => this.tripLine(label, trip, end))
    if (back && sameWay === false) {
      lines.push(Object.assign(document.createElement("p"), {
        className: "trail-trip-line text-body-secondary",
        textContent: "The same way back doesn't run after the hike, or takes much longer, so this goes another way."
      }))
    }
    box.replaceChildren(...lines)
    box.hidden = lines.length === 0
  }

  // The rides there and back. Sorting and filtering use them from the next change,
  // so cards don't move while they're read.
  showTravel(card, there, back) {
    card.querySelector("[data-travel-time]").textContent = duration(there + back)
    card.querySelector("[data-travel-detail]").textContent = `${duration(there)} there · ${duration(back)} back`
    card.dataset.travel = (there + back) * 60
  }

  // When the card's sunset is, if it has one.
  sunset(card) {
    const sunset = card.querySelector("[data-sunset]")?.dataset.sunset
    return sunset ? new Date(sunset) : null
  }

  // Whether sunset is the hike's deadline rather than the last trip back, which
  // has to leave the margin after the hike, like TripPlans.sunset_first?.
  sunsetFirst(card, last) {
    const sunset = this.sunset(card)
    const margin = (Number(card.dataset.required) - Number(card.dataset.hike)) * 1000
    return Boolean(sunset) && sunset <= new Date(last.departure) - margin
  }

  // Whether arriving by the trip there leaves time to hike by sunset and
  // before the last trip back, where there is one, as searches require.
  timeToHike(card, there, last) {
    const arrival = new Date(there.arrival)
    const sunset = this.sunset(card)
    return (!last || new Date(last.departure) - arrival >= Number(card.dataset.required) * 1000) &&
      (!sunset || sunset - arrival >= Number(card.dataset.hike) * 1000)
  }

  // Takes a hike its planned trips leave no time for off the page.
  drop(card) {
    this.previews.unobserve(card)
    this.trips.unobserve(card)
    card.remove()
    this.count()
  }

  // The hike's deadline, sunset or the last trip back, once its trips are
  // planned, and the time there until it.
  showLast(card, last, there) {
    const line = card.querySelector(".trail-return")
    const back = line.querySelector("[data-return]")
    if (!back.querySelector("[data-last-return]")) {
      // The search couldn't check the way back, but the planner could.
      const from = card.dataset.plan === "through" ? " from the far end" : ""
      const time = document.createElement("strong")
      time.dataset.lastReturn = ""
      back.replaceChildren(Object.assign(document.createElement("span"), { ariaHidden: "true", textContent: "↩️" }),
        ` Last trip back${from} `, time)
    }
    back.querySelector("[data-last-return]").textContent = this.clock(last.departure)
    const dark = this.sunsetFirst(card, last)
    back.hidden = dark
    const sunsetPart = line.querySelector("[data-sunset]")
    if (sunsetPart) sunsetPart.hidden = !dark
    if (!there) return

    const end = dark ? this.sunset(card) : new Date(last.departure)
    const stay = Math.max(Math.floor((end - new Date(there.arrival)) / 60000), 0)
    line.querySelector("[data-stay-label]").textContent = `· up to ${stayLabel(stay)}${dark ? " of daylight" : ""} there`
  }

  tripLine(label, trip, end) {
    const line = document.createElement("p")
    line.className = "trail-trip-line"
    const heading = document.createElement("strong")
    heading.textContent = `${label}: `
    line.append(heading)
    const legs = trip.legs.length ? trip.legs : [{ mode: "WALK", name: "Walk" }]
    legs.forEach((leg, index) => {
      if (index > 0) line.append(" → ")
      const span = document.createElement("span")
      span.className = "trail-leg"
      span.textContent = leg.mode === "WALK" ? "🚶 Walk" : `${modeIcon(leg.mode)} ${leg.name || ""}`.trim()
      span.title = [leg.agency, leg.headsign && `to ${leg.headsign}`].filter(Boolean).join(" ")
      line.append(span)
    })
    line.append(` · leave ${this.clock(trip.departure)}, ${end} ${this.clock(trip.arrival)}`)
    return line
  }

  clock(time) {
    const options = { hour: "numeric", minute: "2-digit", timeZone: this.timeZone }
    try {
      return new Date(time).toLocaleTimeString([], options)
    } catch {
      return new Date(time).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    }
  }
}


// Wikimedia serves any image at standard thumbnail widths, such as 120 px for the gallery.
const thumbnail = (url) => url.replace(/\/\d+px-/, "/120px-")

async function showPhotos(card, preview) {
  const link = card.querySelector("[data-photos-url]")
  const response = await fetch(link.dataset.photosUrl, { headers: { Accept: "application/json" } })
  if (response.status !== 200) return

  const { photos } = await response.json()
  const image = link.querySelector("img")
  const gallery = card.querySelector("[data-gallery]")
  const show = (photo, button) => {
    image.addEventListener("load", () => {
      link.href = photo.file_url
      link.querySelector(".trail-photo-caption").textContent = photo.caption
      if (link.hidden) {
        link.hidden = false
        card.querySelector(".trail-media").classList.add("has-photo")
        preview.map.invalidateSize()
        preview.fit()
      }
      const source = Object.assign(document.createElement("a"), {
        href: photo.file_url, target: "_blank", rel: "noopener", textContent: photo.credit
      })
      const credit = card.querySelector(".trail-photo-credit")
      credit.replaceChildren("Photo: ", source)
      credit.hidden = false
    }, { once: true })
    image.alt = photo.caption
    image.src = photo.image_url
    gallery.querySelectorAll(".trail-thumb").forEach((thumb) => thumb.setAttribute("aria-pressed", String(thumb === button)))
  }
  if (photos.length > 1) {
    gallery.replaceChildren(...photos.map((photo, index) => {
      const button = Object.assign(document.createElement("button"), { type: "button", className: "trail-thumb" })
      button.setAttribute("aria-label", `Photo ${index + 1} of ${photos.length}: ${photo.caption}`)
      button.append(Object.assign(document.createElement("img"), {
        src: thumbnail(photo.image_url), alt: "", loading: "lazy", decoding: "async"
      }))
      button.addEventListener("click", () => show(photo, button))
      return button
    }))
    gallery.hidden = false
  }
  show(photos[0], gallery.querySelector(".trail-thumb"))
}

document.addEventListener("DOMContentLoaded", () => {
  const toggle = document.querySelector("[data-search-toggle]")
  const search = toggle && new SearchToggle(toggle)
  const page = document.querySelector("[data-stream-url]")
  if (page) new Results(page, search).stream()
})
