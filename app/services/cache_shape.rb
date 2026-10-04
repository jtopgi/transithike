require "digest"

# A short fingerprint of structs' members, for the keys of cache entries that
# hold them: the cache outlives deploys, and an entry whose struct has gained
# or lost a member since can't be read, so a change to one starts new keys.
module CacheShape
  def self.of(*structs)
    Digest::SHA256.hexdigest(structs.map { |struct| "#{struct.name}(#{struct.members.join(',')})" }.join(";"))[0, 8]
  end
end
