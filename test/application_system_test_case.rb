require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1400]
end

# Chrome reports an element the page moved as it was read ("Node with given id does
# not belong to the document") as an unknown error rather than a stale element, so
# Capybara looks for it again, as it does for stale elements, rather than fail.
Capybara::Selenium::Driver.prepend(Module.new do
  def invalid_element_errors
    super + [Selenium::WebDriver::Error::UnknownError]
  end
end)
