class User < ActiveRecord::Base
  include ::NewRelic::Agent::MethodTracer
  include Dealer360Secret::PermissionsModule
  include Dealer360Secret::UserDevise
  include NbUser
  include AstUser
  include D360Core::UserModule

  ## trace methods from Dealer360Secret::PermissionsModule
  add_method_tracer :fetch_permissions_and_roles, 'Custom/Dealer360Secret::PermissionsModule/fetch_permissions_and_roles'
  add_method_tracer :is_member?, 'Custom/Dealer360Secret::PermissionsModule/is_member'
  add_method_tracer :cached_permissions_and_roles, 'Custom/Dealer360Secret::PermissionsModule/cached_permissions_and_roles'

  if Rails.env.development?
    begin
      model_list = Programs::CustomClassMapping::MAPPING.values.collect{|c| c=c.constantize;c.valid_content_types}.flatten
      model_list += Permission.select("distinct model_name").pluck(:model_name)
      model_list.flatten.uniq.each do |model_name|
      begin; model_name.to_s.constantize unless model_name.to_s=="all"; rescue; end
    end
    rescue
    end
  end

  NOT_SHOW_POSITION = [110,120]
  SUPPORTED_AVATAR_FORMATS = ['image/png', 'image/jpeg', 'image/pjpeg', 'image/bmp', 'image/gif','image/x-png']
  AVATAR_SIZE = 2.megabytes
  TMP_AVATAR_NAME = "avatar_tmp"
  FOM_USER_TITLE = "Fixed Ops Mgr"
  DOM_USER_TITLE = "Dealer Ops Mgr"
  COUNTRIES_HASH = {
      "United States" => "USA",
      "India" => "IND",
      "Mexico" => "MEX",
      "Canada" => "CAN",
      "Brazil" => "BRA"
  }
  USER_TYPES = {
      :oem => "OEM",
      :dealership => "Dealership",
      :vendor => "Vendor",
      :provider => "Provider"
  }

  PRIMARY_DATA_SOURCES = {
      :sso => "SSO",
      :square_root => "square-root",
      :hr => "HR"
  }

  USER_STATUS_TYPES = ["All","Online","Offline","Active","Inactive"]
  SORTABLE_FIELDS = ["name","id","login","email","custom_user_type"]

  USER_TYPE_MAPPING = { :All => 'A',
                        :Dealer => 'D',
                        :Corporate => 'C',
                        :Vendor => 'V',
                        :Internal => 'I',
                        :Other => 'O'
  }
  belongs_to :position
  has_one :user_profile
  has_one :user_log
  has_one :badge_point
  # user has community20 badge points
  has_one :community20_badge_points, :class_name => 'Community20::BadgePoint'
  has_and_belongs_to_many :dealerships, :join_table => :entity_users, :foreign_key => 'user_id', :association_foreign_key => 'entity_id'
  has_and_belongs_to_many :vendors, :join_table => :users_vendors, :foreign_key => 'user_id', :association_foreign_key => 'vendor_id'
  has_and_belongs_to_many :designations, :join_table => :users_designations

  # Each user will have a Brand associated with it.
  # By default this will be nil unless set either through login, data import or the user details page
  belongs_to :brand

  accepts_nested_attributes_for :user_profile
  accepts_nested_attributes_for :user_log
  accepts_nested_attributes_for :roles

  attr_accessor :nna_import_name, :organization_temp, :position_temp, :current_entity

  has_attached_file :avatar,
      AVATAR_STORAGE_OPTIONS.merge(
          :styles => { :original => "300x300#", :medium => "150x150#", :thumb => "30x30#" },
          :default_url => "/assets/avatar_default.png",
          :s3_domain_url=> :custom_url
      ).merge(S3_PROXY_CONFIG.nil?? {} : {:http_proxy=>{:host=>S3_PROXY_CONFIG["host"],:port=>S3_PROXY_CONFIG["port"]}})

  attr_accessible :avatar, :community_weekly_digest_status, :topic_auto_subscription_status,
    :status, :user_profile_attributes, :nna_import_name, :login, :organization_temp,
    :position_temp, :provider, :uid


  delegate :current_sign_in_ip, :last_sign_in_ip, :sign_in_count, :current_sign_in_at,
    :last_sign_in_at, to: :user_log, allow_nil: true, prefix: false

  delegate :full_name, :to => :user_profile, :allow_nil => true, :prefix => true
  delegate :pri_phone, :to => :user_profile, :allow_nil => true, :prefix => true
  delegate :d360_alt_phone, :to => :user_profile, :allow_nil => true, :prefix => true
  delegate :title, :to => :user_profile, :allow_nil => true, :prefix => true
  delegate :state, :to => :user_profile, :allow_nil => true, :prefix => true
  delegate :name, :to => :position, :allow_nil => true, :prefix => true
  delegate :points, :to => :badge_point, :allow_nil => true, :prefix => false
  delegate :show_contact_info, :to => :user_profile, :allow_nil => true, :prefix => false
  delegate :country, :to => :user_profile, :allow_nil => true, :prefix => false
  delegate :can?, :cannot?, :to => :ability

  email_format = /\A[_a-z0-9-]+([\.\+]?[_a-z0-9-]+)*@[a-z0-9-]+(\.[a-z0-9-]+)*(\.[a-z]{2,4})\Z/i
  validates_format_of :email, :allow_blank => true, :with  => email_format
  validates_presence_of :login
  validates_attachment_size :avatar,
    :less_than => AVATAR_SIZE,
    :message => "Please upload file with size less than two megabytes."
  validates_attachment_content_type :avatar,
    :content_type => SUPPORTED_AVATAR_FORMATS,
    :message => "The file you selected is not one of the supported types. Please choose a file with the following extensions: .jpg, .jpeg, .png, .gif, .bmp."

  scope :d360_active, where(:d360_active => true)
  scope :nna, where(:nna => true, :nna_net => true)
  scope :dsm, where(:nna => false, :nna_net => true)
  scope :active, where("`users`.`status` = TRUE")


  # Condition to find online_status of users. Following possible values:
  # Disabled => -1
  # on-line => 1
  # off-line => 0
  def self.online_condition
    <<-eos
    case  when users.status = false then -1
          when user_logs.current_sign_in_at > '#{Time.zone.now - 2.hours}' then 1
          else 0
    end
    eos
  end

  # Scope to find online_status of users. Following possible values:
  scope :online, joins(:user_log).select("#{sanitize_sql(online_condition)} as online_status")

  # Scope to return the grouped counts of users
  scope :group_by_online_status, online.select("count(*) as count").group(online_condition)

  scope :custom_user_type, joins(:user_profile).select(
  <<-eos
  case  when  user_profiles.user_type = 'I' then 'Internal'
        when  user_profiles.user_type = 'V' then 'Vendor'
        when  user_profiles.user_type = 'C' then 'Corporate'
        when  user_profiles.user_type = 'D' then 'Dealer'
        else 'Other'
  end as custom_user_type
  eos
  )

  ###### Scopes for User Status Filter ########
  def self.online_status_filter_condition; "#{online_condition} = 1"; end
  scope :online_filter, where(online_status_filter_condition)

  def self.offline_status_filter_condition; "#{online_condition} = 0"; end
  scope :offline_filter, where(offline_status_filter_condition)

  def self.active_status_filter_condition; "#{online_condition} = 1 or #{online_condition} = 0"; end
  scope :active_filter, where(active_status_filter_condition)

  def self.inactive_status_filter_condition; "#{online_condition} = -1"; end
  scope :inactive_filter, where(inactive_status_filter_condition)

  ## this scope should be used when Users are to be filtered
  # using multiple statues
  # it will iterate over status and create a SQL query that
  # will be used to filter users
  scope :multi_status_filter, lambda {|statuses_arr|
    sql_condition = []
    statuses_arr.each do |status|
      status = status.to_s.downcase
      method_name = "#{status}_status_filter_condition"
      sql_condition << send(method_name) if respond_to?(method_name)
    end
    where(sql_condition.join(" OR "))
  }

  ## this scope should be used when Users are to be filtered
  # using multiple user types.
  # it will iterate over user types and create a SQL query that
  # will be used to filter users
  scope :multi_type_filter, lambda {|types_arr|
    sql_condition = []
    types_arr.each do |type|
      type = type.to_s.to_sym
      if type==:Other
        sql_condition << " user_profiles.user_type is null or user_profiles.user_type not in ('C','D','V','I')"
      else
        sql_condition << " user_profiles.user_type = '#{USER_TYPE_MAPPING[type]}' "
      end
    end
    where(sql_condition.join(" OR "))
  }

  ## scope used to add initial scopes to User search query
  scope :add_filter_scopes, custom_user_type.online


  ## generic method for adding different filters to the
  # User filter scoped query
  def self.filter(params={})
    scoped_rel = self
    scoped_rel = scoped_rel.user_type_filter(scoped_rel, params)
    scoped_rel = scoped_rel.status_filter(scoped_rel, params)
    scoped_rel
  end

  ## method for filtering users by Type of the User
  def self.user_type_filter(scoped_rel, params={})
    scope = scoped_rel.joins(:user_profile)
    user_type_filter = params[:user_type_filter]
    if user_type_filter
      type_filter = nil
      types_filters = user_type_filter.to_s.split(",")
      if types_filters.include?("All")
        type_filter = scope
      else
        type_filter = scope.send(:multi_type_filter, types_filters)
      end
      type_filter
    else
      scope
    end
  end

  ## method for filtering users by Status of the User
  # It can be Online, Offline, Active and Inactive
  # Active users can be either online or offline
  def self.status_filter(scoped_rel, params={})
    user_status_filter = params[:user_status_filter]
    if user_status_filter
      status_filter = nil
      status_filters = user_status_filter.to_s.split(",")
      if status_filters.include?("All")
        status_filter = scoped_rel.scoped
      else
        status_filter = scoped_rel.send(:multi_status_filter,status_filters)
      end
      status_filter
    else
      scoped_rel.active_filter
    end
  end

  # Returns column on which sorting is to be done
  # In case of name also include f_name and m_name, l_name
  def self.sort_column param_sort
    order_field = SORTABLE_FIELDS.include?(param_sort) ? param_sort : SORTABLE_FIELDS[0]
    order_field = "coalesce(users.name,f_name,m_name,l_name)" if order_field == SORTABLE_FIELDS[0]
    order_field
  end

  ############ Defining Sphinx Indexes ##############
  define_index do
    indexes :name
    indexes :email
    #indexes user.roles.name
    indexes user_profile.f_name
    indexes user_profile.m_name
    indexes user_profile.l_name
    indexes user_profile.title
    indexes dealerships(:name), :as => :dealership_name
    indexes dealerships(:code), :as => :dealership_code
    indexes vendors(:name), :as=> :vendor_name

    has '1', :as => :profile_visible, :type=>:boolean #used for searching with dealership on home page
    has '0', :as => :dealer_brand_id, :type=>:boolean #used for searching with dealership on home page
    has :status
    has :d360_active
    has :nna_net
    has :id, :as => :user_id
    has :is_mgr, :as => :manager # used in d360_core user
    has :nna
    has :brand_id
    has dealerships(:id), :as => :dealership_ids, :type => :multi

    where "status = true AND (login NOT LIKE '%-DEL' or login is null)"
  end

  ###These setter methods are added in PLAT-2544 to move user logging methods to user_logs table.
  ###To avoid overriding devise method for adding tracking info, we created these setter methods.
  def log
    self.user_log || self.build_user_log
  end

  def last_sign_in_at=(value)
    log.last_sign_in_at = value
  end

  def current_sign_in_at=(value)
    log.current_sign_in_at = value
  end

  def last_sign_in_ip=(value)
    log.last_sign_in_ip = value
  end

  def current_sign_in_ip=(value)
    log.current_sign_in_ip = value
  end

  def sign_in_count=(value)
    log.sign_in_count = value
  end
  ################################################################################################

  def inactive_vendor
    update_attribute(:status, false) if self.nna_net == false
  end

  #cache all the permissions in the marshal format at model level
  def ability
    current_ability =  Rails.cache.fetch("ability_#{self.id}", :expires_in => 30.minutes) do
      Marshal::dump Ability.new(self)
    end
    @ability = Marshal::load current_ability
    @ability
  end

  #Returns bollean whether users ability class is cache or not
  def get_ability_cache
    Rails.cache.read("ability_#{self.id}").present?
  end

  ## method for clearing ability cache for the User with id
  # given as params
  def self.clear_ability_cache(user_id=nil)
    if user_id.blank?
      Rails.cache.delete_matched('^ability_')
    else
      Rails.cache.delete("ability_#{user_id}")
    end
  end

  ## method for clearing ability cache for the corresponding User
  def clear_ability_cache
    User.clear_ability_cache(self.id)
  end

  ## method to clear available programs cache for user
  def clear_available_programs_cache
    Programs::User.clear_available_programs_cache([self.id])
  end

  ## method to clear all user cache on login
  def clear_all_cache
    self.clear_permissions_and_roles
    self.clear_managers_and_reporters
    self.clear_ability_cache
    self.clear_available_programs_cache
  end

  def get_email
    if self.nna? || self.dsm?
      self.user_profile.try(:d360_primary_email_status) ?
      self.user_profile.try(:d360_alt_email) : self.email
    else
      self.email || self.user_profile.try(:profile_email)
    end
  end

  # Returns the d360_alt_phone if populated. Otherwise returns the NNANET primary phone
  def get_phone_number
    self.user_profile_d360_alt_phone.blank? ? self.user_profile_pri_phone :
        self.user_profile_d360_alt_phone
  end

  def get_phone
    if self.nna? || self.dsm?
      self.user_profile.try(:d360_primary_phone_status) ?
      self.user_profile.try(:d360_alt_phone) : self.user_profile.try(:pri_phone)
    else
      self.user_profile.try(:pri_phone)
    end
  end

  def position_title
    self.position.try(:name) unless NOT_SHOW_POSITION.include?( self.position.try(:code) )
  end

  #============ Functions for user details page in user_management scope ================#

  ## Function to return job title for user details page in user_management scope
  #
  # Returns title saved in user's profile if not blank, otherwise returns the user's position title.
  def user_details_title
    title = self.user_profile.try(:title)
    title = self.position_title if title.blank?
    title
  end

  ## Function returns the online status of the user
  #
  # Return values:
  # >  -1 => Inactive
  # >  0 => Offline
  # >  1 => Online
  def current_online_status
    unless self.status
      return -1
    else
      if !self.current_sign_in_at.blank? && self.current_sign_in_at > (Time.zone.now - 2.hours)
        return 1
      else
        return 0
      end
    end
  end

  # Function returns a hash that has an element for each permission that the user has from a role or group
  def get_permissions_from_roles_and_groups(per_page,page,sort_field=nil,sort_direction=nil)
    user_group_ids = self.groups
    permissions_hash = {}
    permissions = []
    roles_perm_sql = self.permissions.joins(:roles,:application).select(
                                              "permissions.name as permission_name,
                                               roles.name as role_name,
                                               applications.name as application_name,
                                               NULL as group_name").to_sql
    roles_perm_sql += " UNION "+Group.where(:id => user_group_ids).joins(
                                              :roles => [:permissions,:application]).select(
                                              "permissions.name as permission_name,
                                               roles.name as role_name,
                                               applications.name as application_name,
                                               groups.name as group_name").to_sql unless user_group_ids.blank?
    roles_perm_sql += " order by #{user_details_permissions_sort_column(sort_field)} #{sort_direction(sort_direction)}"
    roles_perms = ActiveRecord::Base.connection.execute(roles_perm_sql)

    roles_perms.each do |perm|
      if perm[3].blank?
        if permissions_hash[perm[0]].blank?
          permissions_hash[perm[0]] = permissions.length
          permissions << {permission_name: perm[0], roles: [perm[1]], application_name: perm[2]}
        else
          role = perm[1]
          permissions[permissions_hash[perm[0]]][:roles] << role unless permissions[permissions_hash[perm[0]]][:roles].include?(role)
        end
      else
        if permissions_hash[perm[0]].blank?
          permissions_hash[perm[0]] = permissions.length
          permissions << {permission_name: perm[0], roles: [perm[1]+"("+perm[3]+")"], application_name: perm[2]}
        else
          role = perm[1]+"("+perm[3]+")"
          permissions[permissions_hash[perm[0]]][:roles] << role unless permissions[permissions_hash[perm[0]]][:roles].include?(role)
        end
      end
    end
    permissions.paginate(:per_page => per_page, :page => page)
  end

  USER_PERMISSIONS_SORTABLE_FIELDS = ["permission_name","application_name"]

  def user_details_permissions_sort_column(column_name)
    USER_PERMISSIONS_SORTABLE_FIELDS.include?(column_name) ? column_name : USER_PERMISSIONS_SORTABLE_FIELDS.first
  end

  def sort_direction(direction)
    %w[asc desc].include?(direction) ? direction : "asc"
  end

  #============ End of Functions for user details page in user_management scope ================#

  def user_name
    (self.user_profile_full_name || self.name).to_s
  end

  def nna?
    self.nna && self.nna_net
  end

  def dsm?
    !self.nna && self.nna_net
  end

  def multi_dealer_dsm?
    self.dsm? && self.dealerships.length > 1
  end

  # returns true if user is managed by NNA
  # based on value of user_type and primary_data_source
  def nna_mastered?
    self.primary_data_source == PRIMARY_DATA_SOURCES[:hr] || self.primary_data_source == PRIMARY_DATA_SOURCES[:sso]
  end

  # returns true if user is managed by Square-root
  # based on value of user_type and primary_data_source
  def sr_mastered?
    self.primary_data_source == PRIMARY_DATA_SOURCES[:square_root]
  end

  def total_active
    (spa_status && nna_net) || (d360_active && !nna_net)
    # in future replaced by spa_status = d360_active
  end

  def spa_status
    status
  end

  def for_search
    # users only from white_list
    # 9 users :)
  end

  def self.search_active_users_by_name(scope, name)
    search_user_name(scope,name).where("status = true AND users.login NOT LIKE '%-DEL'")
  end

  def self.search_user_name(scope,name)
    scope = scope.joins(:user_profile).select("Distinct users.*")

    # No '%' at the beginning of the search term so that MySQL can use indexes.
    # Indexes are ignored when '%' is given at the start of the search term.
    name = "#{name.downcase.split(" ").join("%")}%"

    # Build queries for each condition
    name_query = scope.where("users.name like ?", name).to_sql
    login_query = scope.where("users.login like ?", name).to_sql
    f_name_query = scope.where("user_profiles.f_name like ?", name).to_sql
    l_name_query = scope.where("user_profiles.l_name like ?", name).to_sql

    # UNION all queries(instead of OR conditions). This optimizes the query.
    sql = "((#{name_query}) UNION (#{login_query}) UNION (#{f_name_query}) UNION (#{l_name_query})) AS users"

    User.from(sql).select("Distinct users.*")
  end

  def self.db_search(attrs = {})
    scope = User.scoped
    if attrs[:user_name].blank?
      scope = scope.select("users.*")
    else
      scope = search_user_name(scope,attrs[:user_name])
    end
    # Adding online_status to select list
    scope = scope.online
    scope = scope.custom_user_type

    if attrs[:test_user].blank?
      scope = scope.where("primary_data_source != 'square-root' ")
    else
      scope = scope.where(:primary_data_source => 'square-root')
    end
    unless attrs[:status].blank?
      # status is inactive?
      conditions = { :status => attrs['status'].to_s=="true" }
      scope = scope.where(conditions)
    end
    apply_order(scope, attrs)
  end

  def self.db_group_search attrs={}
    if !attrs[:group_id].blank?
      scope = Group.find(attrs[:group_id].to_i).users.joins(:user_profile).select("distinct users.*")
    else
      scope = User.scoped.joins(:user_profile).select("distinct users.*")
    end
    conditions = attrs[:test_sql_rule]

    scope = scope.online
    scope = scope.where(conditions)
    unless attrs[:status].blank?
      # status is inactive?
      conditions = { :status => attrs['status'].to_s=="true" }
      scope = scope.where(conditions)
    end
    apply_order(scope, attrs)
  end

  def role_select
    user_roles = self.roles.pluck(:id)
    if !user_roles.blank?
      scope = Role.select("id, application_id,name").where("id not in (?)",user_roles)
    else
      scope = Role.select("id, application_id,name")
    end
    scope.map{|r| ["#{r.id}. #{r.name} - #{Application.find(r.application_id).name}", r.id]}
  end

  def self.apply_order(scope, attrs)
    # to prevent XSS injections
    attrs = attrs.reverse_merge(:sort_field => "user_profiles.f_name") unless attrs[:sort_field]
    scope = scope.order("#{attrs[:sort_field]} #{attrs[:sort_dir]}")
    scope
  end

  # TODO add tockens if needed
  def self.api_authenticate(login, password)
    if(DEALER360_API_CREDENTIALS.present? && DEALER360_API_CREDENTIALS.is_a?(Hash) && DEALER360_API_CREDENTIALS['username'].present? &&
        DEALER360_API_CREDENTIALS['password'].present?)
      login == DEALER360_API_CREDENTIALS['username'] && password == DEALER360_API_CREDENTIALS['password']
    else
      false
    end
  end

  ## method to check if a user can see the reporting structure.
  # For seeing reporting structure user should be a nna user and
  # user should related to atleast one person in reporting structure
  def can_see_reporting_structure? user
   self.nna? && ((user.is_mgr && !user.direct_reports.blank?) || (!user.manager.blank?))
  end

  ##method to check who can see the dealership tab.
  def can_see_dealership_tab?
    self.nna?
  end

  ## method to checks if user is a Vendor user
  def vendor_user?
    self.vendors.exists?
  end

  ### method to display name for the header.
  def display_name
    #If name of the user is blank then name stored in user profile is displayed as default else
    #if the user profile name is blank then email is displayed as default.
    self.name.blank? ? ((self.user_profile && !self.user_profile.full_name.blank?)? self.user_profile.full_name : self.email) : self.name
  end

  ## method returns default geographic filter for the user
  def geographic_filters
    UserProfile.select("brand_id,region_id,area_id,district_id").where(:user_id=>self.id).first
  end

  ## Function to check if the google analytics custom variable is to be created for a user.
  def create_ga_custom_var?
    D360Core::FeatureGate.active?(:create_ga_custom_variable, self)
  end

  ## Returns capitalized/titleized name
  def titleized_name
    self.user_name.to_s.squeeze(' ').split(' ').collect(&:capitalize).join(' ')
  end

  def can_view_contact_for?(user)
    self.nna || user.show_contact_info || user.id == self.id
  end

  # Gives temporary directory to store user avatar
  def temp_avatar_dir
    File.join(Rails.public_path, self.temp_avatar_relative_path)
  end

  # Gives relative temp path
  def temp_avatar_relative_path
    "system/avatars/#{self.id}/tmp"
  end

  # Gives full temp file path
  def temp_avatar_file_path ext
    filename = User::TMP_AVATAR_NAME + ext
    File.join(self.temp_avatar_dir, filename)
  end

  # Gives relative temp url where temp file is
  def temp_avatar_url ext
    filename = User::TMP_AVATAR_NAME + ext
    File.join("/", self.temp_avatar_relative_path, filename)
  end

  # Deletes the fil
  def delete_temp_avatar_dir
    FileUtils.rm_rf(self.temp_avatar_dir)
  end

  # Returns nil for vendors, user_profile title for nna and position for dsm users.
  def job_title
    if self.nna?
      self.user_profile.try(:title)
    elsif self.dsm?
      self.position.try(:name)
    end
  end

  # Returns current entity name and code for dsm user when seeing own profile and users dealership and code when viewing
  # another dsm users profile. Returns "Nissan North America" for nna users and nil for vendors.
  def company_title current_user, current_entity=nil
    if (!current_entity.nil? || self.dsm?) && !self.nna?
      ((self == current_user)) ? "#{current_entity.name}- #{current_entity.code}" : nil
    elsif self.nna?
      I18n.t("USER_PROFILE.COMPANY_NAME")
    end
  end

  ## method to return country abbreviation
  # if country is not found in hash it returns nil
  def country_abbr
    country = self.country
    country = country.titleize unless country.nil?
    if COUNTRIES_HASH.has_key?(country)
      COUNTRIES_HASH[country]
    else
      COUNTRIES_HASH["United States"]
    end
  end

  ## method which return type of user Vendor, Dealership or OEM
  def user_type
    provider_match = "oceanus"
    if self.dsm?
      USER_TYPES[:dealership]
    elsif self.vendor_user?
      USER_TYPES[:vendor]
    # For oceanus users you need to return user
    elsif (!self.user_profile.blank? && self.user_profile.title.to_s.downcase.include?(provider_match)) ||
        (!self.email.blank? && self.email.to_s.include?(provider_match))
      USER_TYPES[:provider]
    else
      USER_TYPES[:oem]
    end
  end

  ## method return Users subscriptions to other users but only those
  # which are active
  def get_user_subscriptions
    self.subscriptions(User.name).joins(" INNER JOIN users u on u.id=\
      d360_core_subscribes.content_id").where("u.status = true")
  end

  ##method returns true if user has permission to access admin pages
  def can_access_admin_pages?
    can?("access_global_admin_pages","all")
  end

  def can_be_provisioned_to_coef?
    can?("provision_coefficient_user","all")
  end

  ## method that will check the user is an ADMIN User
  def impersonation_allowed?
    can? :allow_impersonation, "all"
  end

  ##Method to check whether user has 'can_access_across_entity' permission over object
  def can_access_across_entity?(object, current_container=nil)
    if current_container.nil?
      self.can?('can_access_across_entity',object)
    else
      self.can?('can_access_across_entity', current_container)
    end
  end

  ##Method to check if user can access entity object/dealership
  def can_access_entity_object?(object,current_dealer=nil, current_container=nil)
    user_entity = self.current_entity.nil?? self.dealerships.collect(&:id) : [self.current_entity.id]
    entities = current_dealer.blank? ? user_entity : [current_dealer.id]
    if self.can_access_across_entity?(object, current_container)
      true
    elsif !entities.blank?
      if object.respond_to?(:dealership)
        entities.include?(object.dealership.id)
      elsif object.respond_to?(:dealerships)
        (object.dealerships.pluck(:id) & entities).present?
      else
        false
      end
    else
      false
    end
  end

  def after_token_authentication
    update_attributes :authentication_token => nil
  end

  def generate_authentication_token
    self.reset_authentication_token!
  end

  # Function that returns the name of the brand associated with this user
  # Returns nil if no brand is set
  def brand_name
    self.user_brand.try(:name)
  end

  # Returns user brand object
  # This method should be used by all engines/code to fetch the brand of
  # the user.
  def user_brand
    self.brand || Brand.find_by_name(Settings.default_brand)
  end

  # Function to update user brand if given brand is different from current user brand and
  # log any errors to rails logs and sentry
  def update_brand(brand)

    # Set and save the given brand in user object
    self.update_attribute(:brand, brand)

    # Check for errors and log them if any are found
    if self.errors.present?
      error_message = 'Error while updating user brand.\n'
      error_message += "Errors: #{self.errors.messages.collect{|e | e.last.first.to_s}.flatten.join(', ')}"

      # Logging error to sentry and rails logs
      D360Core::D360_Logger.error(StandardError.new(error_message),true)
    end
  end

  def can_access_contact_support?
    !D360Core::FeatureGate.active?(:hide_contact_support_dialog, self)
  end

  def can_access_intercom?
    !D360Core::FeatureGate.active?(:hide_intercom_icon, self)
  end
end
