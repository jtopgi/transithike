require "test_helper"

# Production protects forms against forgery, which stores a CSRF token in the
# session cookie that browsers send back with every later request.
class SessionCookieTest < ActionDispatch::IntegrationTest
  setup do
    @forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @forgery_protection
  end

  test "pages still render when the browser returns its session cookie" do
    get root_path
    assert_response :success
    assert_predicate cookies["_transithike_session"], :present?

    get root_path
    assert_response :success
    get search_path, params: { origin: "" }
    assert_response :unprocessable_content
  end
end
