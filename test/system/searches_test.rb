require "application_system_test_case"

class SearchesTest < ApplicationSystemTestCase
  test "search form is accessible and styled without legacy JavaScript" do
    visit root_url

    assert_selector "h1", text: "New Search"
    assert_field "📍Origin"
    assert_select "🥾 Maximum Length (miles)", options: (1..30).map(&:to_s)
    assert_selector "input[type=submit].btn-primary"
    assert_equal "rgb(13, 110, 253)", page.evaluate_script(
      "getComputedStyle(document.querySelector('input[type=submit]')).backgroundColor"
    )
  end
end
