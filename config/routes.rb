Rails.application.routes.draw do
  # For details on the DSL available within this file, see https://guides.rubyonrails.org/routing.html
  resource :search, only: [:new, :show]
  get "search/stream" => "search_streams#show", as: :search_stream
  get "trip" => "trips#show", as: :trip, defaults: { format: :json }
  get "places" => "places#index", as: :places, defaults: { format: :json }
  get "photos" => "photos#index", as: :photos, defaults: { format: :json }
  get "hike" => "hikes#show", as: :hike

  # Weekly guides that search engines and AI assistants can read, and what tells them about the site's pages.
  slug = /[a-z0-9]+(?:-[a-z0-9]+)*/
  get "day-hikes-by-train" => "guides#index", as: :guides
  get "day-hikes-by-train/:city" => "guides#show", as: :guide, constraints: { city: slug }
  get "day-hikes-by-train/:city/:hike" => "guides#hike", as: :guide_hike, constraints: { city: slug, hike: slug }
  get "robots.txt" => "seo#robots", as: :robots, format: false
  get "sitemap.xml" => "seo#sitemap", as: :sitemap, defaults: { format: :xml }, format: false
  get "llms.txt" => "seo#llms", as: :llms, format: false

  # Liveness check for the container host and uptime monitors.
  get "up" => "rails/health#show", as: :rails_health_check

  root to: "searches#new"
end
