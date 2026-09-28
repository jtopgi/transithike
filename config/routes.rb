Rails.application.routes.draw do
  # For details on the DSL available within this file, see https://guides.rubyonrails.org/routing.html
  resource :search, only: [:new, :show]

  # Liveness check for the container host and uptime monitors.
  get "up" => "rails/health#show", as: :rails_health_check

  root to: "searches#new"
end
