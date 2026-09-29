// Results page: streams hikes in as they are found, then sorts, filters, and previews them.
import * as L from "leaflet"

const TILES = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
const LENGTHS = { any: [0, Infinity], short: [0, 3], medium: [3, 6], long: [6, Infinity] }
// Ties keep the recommended order.
const byScore = (a, b) => b.dataset.score - a.dataset.score || a.dataset.duration - b.dataset.duration
const ascending = (key) => (a, b) => a.dataset[key] - b.dataset[key] || byScore(a, b)
const descending = (key) => (a, b) => b.dataset[key] - a.dataset[key] || byScore(a, b)
const ORDERS = {
  recommended: byScore,
  duration: ascending("duration"),
  stay: descending("stay"),
  distance: ascending("distance"),
  popular: descending("popularity"),
  scenic: descending("scenic"),
  "length-asc": ascending("length"),
  "length-desc": descending("length")
}
const MODE_ICONS = {
  BUS: "🚌", COACH: "🚍", TRAM: "🚊", SUBWAY: "🚇", METRO: "🚇", FERRY: "⛴️",
  FUNICULAR: "🚞", AERIAL_LIFT: "🚡", AREAL_LIFT: "🚡", CABLE_CAR: "🚡"
}
const modeIcon = (mode) => MODE_ICONS[mode] || (/RAIL|SUBURBAN|LONG_DISTANCE/.test(mode) ? "🚆" : "🚏")

class Results {
  constructor(page) {
    this.page = page
    this.list = page.querySelector("[data-trails]")
    this.toolbar = page.querySelector("[data-results-toolbar]")
    this.progress = page.querySelector("[data-progress]")
    this.found = 0
    this.done = false
    // Trips are looked up one card at a time: the transit planner answers each visitor's requests in turn.
    this.tripQueue = Promise.resolve()
    this.previews = new IntersectionObserver((entries) => this.visible(entries, (card) => this.preview(card)),
      { rootMargin: "200px" })
    this.trips = new IntersectionObserver((entries) => this.visible(entries, (card) => this.queueTrip(card)),
      { rootMargin: "100px" })
    this.toolbar.addEventListener("change", () => this.update())
  }

  stream() {
    const events = new EventSource(this.page.dataset.streamUrl)
    const on = (name, handler) => events.addEventListener(name, (event) => handler(JSON.parse(event.data)))
    on("place", (place) => this.place(place))
    on("checking", ({ count }) => this.status(this.found
      ? `Found ${this.found} so far. Checking ${count} more hikes…`
      : `Checking trains, buses, and ferries to ${count} hikes and back…`))
    on("trails", ({ html }) => this.add(html))
    on("ranking", () => this.status("Adding highlights and popularity…"))
    on("update", ({ trails }) => this.refresh(trails))
    on("done", (summary) => { events.close(); this.finish(summary) })
    on("failure", ({ message }) => { events.close(); this.fail(message) })
    events.addEventListener("error", () => {
      // EventSource reconnects on its own, which would start the search over.
      events.close()
      if (!this.done) this.fail("The connection was lost. Please search again.")
    })
  }

  place({ heading, departure, time_zone: timeZone }) {
    this.page.ownerDocument.querySelector("[data-heading]").textContent = heading
    this.page.ownerDocument.querySelector("[data-departure]").textContent = departure
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
      this.list.append(card)
      this.previews.observe(card)
    })
    this.found += cards.length
    this.toolbar.hidden = false
    this.update()
  }

  // Highlights and popularity rank the hikes once every batch is checked.
  refresh(trails) {
    trails.forEach(({ id, score, popularity, scenic, chips }) => {
      const card = this.list.querySelector(`[data-osm-id="${Number(id)}"]`)
      if (!card) return

      Object.assign(card.dataset, { score, popularity, scenic })
      card.querySelector("[data-chips]").innerHTML = chips
    })
    this.update()
  }

  finish({ count, notices }) {
    this.done = true
    this.progress.hidden = true
    this.list.querySelectorAll("[data-skeleton]").forEach((skeleton) => skeleton.remove())
    this.page.querySelector("[data-empty]").hidden = count > 0
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
    }
  }

  notify(messages) {
    const box = this.page.querySelector("[data-notices]")
    box.replaceChildren(...messages.map((message) => Object.assign(document.createElement("p"), {
      className: "mb-0", textContent: message
    })))
    box.hidden = messages.length === 0
  }

  update() {
    const [min, max] = LENGTHS[this.toolbar.querySelector('input[name="length"]:checked').value]
    const maxTrip = Number(this.toolbar.querySelector("[data-max-trip]").value) * 60 || Infinity
    const cards = [...this.list.querySelectorAll("[data-trail]")]
    let shown = 0
    cards.sort(ORDERS[this.toolbar.querySelector("[data-sort]").value]).forEach((card) => {
      const length = Number(card.dataset.length)
      card.hidden = !(length >= min && length < max && Number(card.dataset.duration) <= maxTrip)
      if (!card.hidden) shown += 1
      this.list.append(card)
    })
    this.toolbar.querySelector("[data-results-count]").textContent = `Showing ${shown} of ${cards.length} hikes`
    this.page.querySelector("[data-no-matches]").hidden = shown > 0 || cards.length === 0
  }

  visible(entries, show) {
    entries.filter((entry) => entry.isIntersecting).forEach(({ target }) => show(target))
  }

  preview(card) {
    this.previews.unobserve(card)
    const map = drawMap(card.querySelector(".trail-map"))
    showPhoto(card, map).catch(() => {})
  }

  queueTrip(card) {
    this.trips.unobserve(card)
    this.tripQueue = this.tripQueue.then(() => this.showTrip(card)).catch(() => {})
  }

  async showTrip(card) {
    const box = card.querySelector("[data-trip-url]")
    const response = await fetch(box.dataset.tripUrl, { headers: { Accept: "application/json" } })
    if (!response.ok) return

    const { there, back } = await response.json()
    // The planned trip back is exact to the minute, unlike the search's estimate.
    if (back) card.querySelector(".trail-return strong")?.replaceChildren(this.clock(back.departure))
    const lines = [["There", there, "arrive"], ["Back", back, "home by"]]
      .filter(([, trip]) => trip)
      .map(([label, trip, end]) => this.tripLine(label, trip, end))
    box.replaceChildren(...lines)
    box.hidden = lines.length === 0
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

function drawMap(element) {
  const map = L.map(element, {
    attributionControl: false, zoomControl: false, dragging: false, scrollWheelZoom: false,
    doubleClickZoom: false, boxZoom: false, keyboard: false, touchZoom: false
  })
  L.tileLayer(TILES, { maxZoom: 17 }).addTo(map)
  L.control.attribution({ prefix: false })
    .addAttribution('© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>')
    .addTo(map)
  const route = L.polyline(JSON.parse(element.dataset.path), { color: "#15803d", weight: 4 }).addTo(map)
  L.circleMarker(JSON.parse(element.dataset.start), {
    radius: 6, color: "#fff", weight: 2, fillColor: "#14532d", fillOpacity: 1
  }).bindTooltip("Directions lead here").addTo(map)
  const fit = () => map.fitBounds(route.getBounds(), { padding: [16, 16] })
  fit()
  return { map, fit }
}

async function showPhoto(card, preview) {
  const link = card.querySelector("[data-photo-url]")
  const response = await fetch(link.dataset.photoUrl, { headers: { Accept: "application/json" } })
  if (response.status !== 200) return

  const photo = await response.json()
  const image = link.querySelector("img")
  image.addEventListener("load", () => {
    link.href = photo.article_url
    link.querySelector(".trail-photo-caption").textContent = `Near ${photo.title}`
    link.hidden = false
    card.querySelector(".trail-media").classList.add("has-photo")
    preview.map.invalidateSize()
    preview.fit()

    const credit = card.querySelector(".trail-photo-credit")
    const source = document.createElement("a")
    source.href = photo.file_url
    source.target = "_blank"
    source.rel = "noopener"
    source.textContent = photo.credit
    credit.replaceChildren("Photo: ", source)
    credit.hidden = false
  }, { once: true })
  image.alt = `Photo near ${photo.title}`
  image.src = photo.image_url
}

document.addEventListener("DOMContentLoaded", () => {
  const page = document.querySelector("[data-stream-url]")
  if (page) new Results(page).stream()
})
