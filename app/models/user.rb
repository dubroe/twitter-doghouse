# This table represents users of the Twitter Doghouse app
class User < ActiveRecord::Base  
  has_many :doghouses, dependent: :destroy, order: 'created_at desc'
  has_many :active_doghouses, class_name: 'Doghouse', conditions: ["is_released IS NULL"], order: 'created_at desc'
  has_many :request_from_twitters, dependent: :destroy
  
  CACHE_KEY_PREFIX = 'twitter_user_'
  
  # Create a new user from Twitter's omniauth response
  def self.create_with_omniauth(auth)
    create! do |user|
      user.provider = auth["provider"]
      user.uid = auth["uid"]
      user.name = auth["info"]["name"]
      user.nickname = auth["info"]["nickname"]
      user.image = auth["info"]["image"]
      user.token = auth['credentials']['token']
      user.secret = auth['credentials']['secret']
    end
  end
  
  # Authenticate the user with the twitter API
  # Must be called before performing actions such as following, unfollow and tweeting
  def twitter_api_authenticate!
    Twitter.configure do |config|
      config.consumer_key = TWITTER_KEY
      config.consumer_secret = TWITTER_SECRET
      config.oauth_token = token
      config.oauth_token_secret = secret
    end
  end
  
  # Get all of the ids of the Twitter Users that the user follows
  def get_following_hashes
    twitter_api_authenticate!
    following_hashes = []
    cursor = -1
    # Grabs 5000 at a time until the cursor is set to 0
    while cursor != 0
      followings = Twitter.friend_ids(nickname, cursor: cursor)
      followings.ids.each do |id|
        following_hashes << {id: id, screen_name: Rails.cache.read("#{CACHE_KEY_PREFIX}#{id}")}
      end
      cursor = followings.next_cursor
    end
    following_hashes
  end
  
  def self.get_twitter_screen_names(ids)
    screen_names = []
    Twitter.users(ids).each do |user|
      Rails.cache.write "#{CACHE_KEY_PREFIX}#{user.id}", user.screen_name
      screen_names << user.screen_name
    end
    screen_names
  end
end
