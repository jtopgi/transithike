Rails.application.routes.draw do
  # For details on the DSL available within this file, see https://guides.rubyonrails.org/routing.html
  resource :search, only: [:new, :show]
  get "search/stream" => "search_streams#show", as: :search_stream
  get "trip" => "trips#show", as: :trip, defaults: { format: :json }
  get "places" => "places#index", as: :places, defaults: { format: :json }
  get "photos" => "photos#index", as: :photos, defaults: { format: :json }
  get "hike" => "hikes#show", as: :hike

  # Liveness check for the container host and uptime monitors.
  get "up" => "rails/health#show", as: :rails_health_check

  root to: "searches#new"
end
