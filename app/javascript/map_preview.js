// Route maps: a preview on each result card, and a map to explore on a hike's page.
import * as L from "leaflet"

const TILES = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
const STILL = {
  zoomControl: false, dragging: false, scrollWheelZoom: false, doubleClickZoom: false, boxZoom: false,
  keyboard: false, touchZoom: false
}

// Draws the route in element's data-path, with where directions lead (data-start)
// and, for hikes to the far end, where they finish (data-finish).
export function drawMap(element, { interactive = false } = {}) {
  const map = L.map(element, { attributionControl: false, ...(interactive ? { scrollWheelZoom: false } : STILL) })
  L.tileLayer(TILES, { maxZoom: 17 }).addTo(map)
  L.control.attribution({ prefix: false })
    .addAttribution('© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>')
    .addTo(map)
  const route = L.polyline(JSON.parse(element.dataset.path), { color: "#15803d", weight: 4 }).addTo(map)
  const marker = (point, label, fillColor) => L.circleMarker(point, {
    radius: 6, color: "#fff", weight: 2, fillColor, fillOpacity: 1
  }).bindTooltip(label).addTo(map)
  marker(JSON.parse(element.dataset.start), element.dataset.finish ? "Start: directions lead here" : "Directions lead here", "#14532d")
  if (element.dataset.finish) marker(JSON.parse(element.dataset.finish), "Finish: the trip back leaves near here", "#b45309")
  const fit = () => map.fitBounds(route.getBounds(), { padding: [16, 16] })
  fit()
  return { map, fit }
}

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-hike-map]").forEach((element) => drawMap(element, { interactive: true }))
  // Guides' cards without photos preview their routes as they scroll into view.
  const lazy = new IntersectionObserver((entries) => entries.filter((entry) => entry.isIntersecting).forEach(({ target }) => {
    lazy.unobserve(target)
    drawMap(target)
  }), { rootMargin: "200px" })
  document.querySelectorAll("[data-lazy-map]").forEach((element) => lazy.observe(element))
})
