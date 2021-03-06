# This table represents a doghouse entry
# Should have been called DoghouseEntry instead of Doghouse, since Doghouse should represent the collection of DogHouse entries. Oh well :(
class Doghouse < ActiveRecord::Base
  NONE_TWEET = 'none'
  CUSTOM_TWEET = 'custom'
  MAX_MINUTES = 1000 * 24 * 24
  
  belongs_to :user
  belongs_to :request_from_twitter
  
  validates :screen_name, presence: true
  validates :duration_minutes, numericality: {greater_than: 0, less_than_or_equal_to: MAX_MINUTES}
  validates :duration_minutes_multiplier, numericality: {greater_than: 0 }, allow_blank: true
  validate :tweet_lengths_below_max
  
  attr_accessor :duration_minutes_multiplier, :canned_enter_tweet_id, :canned_exit_tweet_id, :expires_in_minutes, :expires_in_hours, :expires_in_days
  attr_accessible :screen_name, :duration_minutes, :enter_tweet, :exit_tweet, :duration_minutes_multiplier, :canned_enter_tweet_id, :canned_exit_tweet_id, :expires_in_minutes, :expires_in_hours, :expires_in_days
  attr_accessible :screen_name, :duration_minutes, :request_from_twitter_id, :enter_tweet, as: :safe_code
  
  before_create :multiply_duration_minutes, if: :duration_minutes_multiplier
  before_create :set_profile_image
  before_save :handle_canned_tweets
  after_create :enter_doghouse_actions
  before_save :update_duration_minutes, on: :update
  after_save :update_job, on: :update, if: :duration_minutes_changed?
  after_destroy :remove_job, unless: :is_released
  
  # Get the date_time when the Doghouse entry will be released (re-followed and exit tweet sent)
  def release_date_time
    created_at + duration_minutes.minutes
  end
  
  # Release entry from doghouse immediately
  def release_now!
    update_attribute(:is_released, true)
    # Tell the delayed job to run now
    Delayed::Backend::ActiveRecord::Job.find(job_id).update_attribute(:run_at,  Time.now)
  end
  
  # Full text for exit tweet including '@...'
  def exit_tweet_full
    tweet_full exit_tweet
  end
  
  # Returns a hash representing how long until the doghouse entry will be released.
  # Hash contains days, hours (<24), and minutes (<60)
  def get_expiry
    expiry_minutes = ((release_date_time - Time.now) / SECONDS_IN_MINUTE).to_i
    expiry_days = expiry_minutes / MINUTES_IN_DAY
    expiry_minutes -= expiry_days * MINUTES_IN_DAY
    expiry_hours = expiry_minutes / MINUTES_IN_HOUR
    expiry_minutes -= expiry_hours * MINUTES_IN_HOUR
    {
      minutes: expiry_minutes,
      hours: expiry_hours,
      days: expiry_days
    }
  end
  
  # Full text for enter tweet
  def enter_tweet_full
    tweet_full enter_tweet
  end
  
  private
    
    # Full text for tweet include '@...' and bitly link
    def tweet_full(tweet)
      "@#{screen_name} #{tweet} #{BITLY_LINK}"
    end
  
    # Actions to perform when a doghouse entry is created
    def enter_doghouse_actions
      user.twitter_api_authenticate! # Authenticate user with twitter
      unfollow!
      create_release_job! 
      Doghouse.delay.send_enter_tweet!(id) # Asynchronously send the enter tweet
    end
    
    # Tell Twitter to have the user unfollow the selected screen name
    def unfollow!
      Twitter.unfollow(screen_name)
    end
    
    # Create the delayed job to release the doghouse entry after the specified duration
    def create_release_job!
      # Store the job id so that it can be retrieved later
      update_attribute(:job_id, Doghouse.delay(run_at: duration_minutes.minutes.from_now).release!(id).id)
    end
    
    # Tell Twitter to send the user's enter doghouse tweet if one exits
    def self.send_enter_tweet!(doghouse_id)
      begin
        doghouse = Doghouse.get_doghouse_and_authenticate doghouse_id
        Twitter.update(doghouse.enter_tweet_full) if doghouse.enter_tweet.present?
      rescue Exception
        logger.info 'Error sending enter tweet'
      end
    end
    
    # Tell Twitter to send the user's exit doghouse tweet if one exits
    def self.send_exit_tweet!(doghouse_id)
      begin
        doghouse = Doghouse.get_doghouse_and_authenticate doghouse_id
        Twitter.update(doghouse.exit_tweet_full) if doghouse.exit_tweet.present?
      rescue
        logger.info 'Error sending exit tweet'
      end
    end
    
    # Release a doghouse entry (refollow the user, send exit tweet, set doghouse entry to 'released'
    def self.release!(doghouse_id)
      doghouse = Doghouse.get_doghouse_and_authenticate doghouse_id
      Twitter.follow(doghouse.screen_name)
      Doghouse.delay.send_exit_tweet!(doghouse.id)
      doghouse.update_attribute(:is_released, true)
    end
    
    # Update the release job if the duration has changed 
    def update_job
      Delayed::Backend::ActiveRecord::Job.find(job_id).update_attribute(:run_at,  created_at + duration_minutes.minutes)
    end
    
    # Remove the release job is the DogHouse entry is destroyed
    def remove_job
      Delayed::Backend::ActiveRecord::Job.find(job_id).destroy
    end
    
    # Handy function get a doghouse entry and authenticate the user with Twitter
    def self.get_doghouse_and_authenticate(doghouse_id)
      doghouse = Doghouse.find(doghouse_id)
      doghouse.user.twitter_api_authenticate!
      doghouse
    end
    
    # Validate that the enter and exit tweets are below 140 chars
    def tweet_lengths_below_max
      errors.add(:enter_tweet, 'Too long') if enter_tweet && (enter_tweet.length + screen_name.length) > MAX_TWEET_CHARS
      errors.add(:exit_tweet, 'Too long') if exit_tweet && (exit_tweet.length + screen_name.length) > MAX_TWEET_CHARS
    end
    
    # Convert the number of hours and days for a Doghouse entry into minutes
    def multiply_duration_minutes
      self.duration_minutes = duration_minutes.to_i * duration_minutes_multiplier.to_i
    end
    
    # Set the enter and exit tweet based on the CannedTweets selected from the form
    # Can either be an integer, meaning it's a canned tweet ID and we should get use text from that canned tweet, 'none' meaning there should be no tweet, 
      # or 'custom', meaning the user selected their own tweet.
    def handle_canned_tweets
      %w(enter exit).each do |direction|
        canned_tweet_id = send("canned_#{direction}_tweet_id")
        if canned_tweet_id
          if canned_tweet_id == NONE_TWEET
            self.send("#{direction}_tweet=", '')
          elsif canned_tweet_id.to_i.nonzero?
            self.send("#{direction}_tweet=", CannedTweet.find(canned_tweet_id).text)
          end
        end
      end
    end
    
    # Store the location of the profile image of the screen_name
    def set_profile_image
      self.profile_image = Twitter.user(screen_name).try(:profile_image_url)
    end
    
    # Called when a user wants to change the expire time of doghouse entry
    def update_duration_minutes
      # Must pass in minutes, hours and days (can be 0) in order to proceed
      if expires_in_minutes.present? && expires_in_hours.present? && expires_in_days.present?
        minutes_so_far = (Time.now - created_at) / SECONDS_IN_MINUTE
        additional_minutes = expires_in_minutes.to_i
        additional_minutes += expires_in_hours.to_i * MINUTES_IN_HOUR
        additional_minutes += expires_in_days.to_i * MINUTES_IN_DAY
        self.duration_minutes = minutes_so_far + additional_minutes
      end
    end
end
