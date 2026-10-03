xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.urlset xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  xml.url { xml.loc root_url }
  if @pages.any?
    xml.url do
      xml.loc guides_url
      xml.lastmod @pages.map(&:built_at).max.utc.iso8601
    end
  end
  @pages.each do |page|
    built = page.built_at.utc.iso8601
    xml.url do
      xml.loc guide_url(page.guide.slug)
      xml.lastmod built
    end
    page.hikes.each do |hike|
      xml.url do
        xml.loc guide_hike_url(page.guide.slug, hike.slug)
        xml.lastmod built
      end
    end
  end
end
