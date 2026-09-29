// Results page: sorting and length filters, route map previews, and nearby photos.
import * as L from "leaflet"

const TILES = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
const LENGTHS = { any: [0, Infinity], short: [0, 3], medium: [3, 6], long: [6, Infinity] }
const ORDERS = {
  duration: (a, b) => a.dataset.duration - b.dataset.duration,
  distance: (a, b) => a.dataset.distance - b.dataset.distance,
  "length-asc": (a, b) => a.dataset.length - b.dataset.length,
  "length-desc": (a, b) => b.dataset.length - a.dataset.length
}

function setUpToolbar() {
  const toolbar = document.querySelector("[data-results-toolbar]")
  const list = document.querySelector("[data-trails]")
  if (!toolbar || !list) return

  const sort = toolbar.querySelector("[data-sort]")
  const count = toolbar.querySelector("[data-results-count]")
  const noMatches = document.querySelector("[data-no-matches]")
  const cards = [...list.querySelectorAll("[data-trail]")]

  const update = () => {
    const [min, max] = LENGTHS[toolbar.querySelector('input[name="length"]:checked').value]
    let shown = 0
    cards.sort(ORDERS[sort.value]).forEach((card) => {
      card.hidden = !(card.dataset.length >= min && card.dataset.length < max)
      if (!card.hidden) shown += 1
      list.append(card)
    })
    count.textContent = `Showing ${shown} of ${cards.length} routes`
    noMatches.hidden = shown > 0
  }

  toolbar.addEventListener("change", update)
  toolbar.hidden = false
  update()
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
  }).bindTooltip("Route start").addTo(map)
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

// Draw maps and look up photos only as cards scroll into view.
function setUpPreviews() {
  const cards = document.querySelectorAll("[data-trail]")
  if (!cards.length) return

  const observer = new IntersectionObserver((entries) => {
    entries.filter((entry) => entry.isIntersecting).forEach(({ target }) => {
      observer.unobserve(target)
      const preview = drawMap(target.querySelector(".trail-map"))
      showPhoto(target, preview).catch(() => {})
    })
  }, { rootMargin: "200px" })
  cards.forEach((card) => observer.observe(card))
}

document.addEventListener("DOMContentLoaded", () => {
  setUpToolbar()
  setUpPreviews()
})
