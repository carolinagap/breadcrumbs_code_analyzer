namespace :d360 do

  desc "Add the system group and role and permissions associated"
  task :seed_system_group, [:logins] => :environment do |t, args|
    logins = args[:logins] || "SQADMIN"

    Dealer360::AdminUser.new.seed

    puts "Creating system admins group"
    user_logins = logins.split(' ').map{|l| l.strip }.select{ |l| /^[A-Za-z0-9]+$/.match l }.map{|l| l.to_s }.join(',')

    sys_admin_group = Group.find_by_name('SYSTEM_ADMINS')

    if !sys_admin_group.present?
      sys_admin_group = Group.new(:name => 'SYSTEM_ADMINS', :user_logins => user_logins)
    end

    sys_admin_group.rule = sys_admin_group.get_rule_from_subparts()
    sys_admin_group.category = Group::CATEGORY[:SYSTEM_ACCESS]
    begin
      sys_admin_group.save!
    rescue ActiveRecord::RecordInvalid => error
      puts "Warning: Some validations failed: "+sys_admin_group.errors.full_messages.to_s+"\nForce creating SYSTEM_ADMINS group."
      sys_admin_group.save(:validate => false)
    else
      puts "SYSTEM_ADMINS group created"
    end

    puts "Creating role admin_pages_moderator and associated permissions"

    application = Application.find_or_create_by_short_name("Core", name: "Core")
    application_id = application.id

    application.engine_name = "Core"
    application.save

    permission_1 = Permission.find_or_create_by_name_and_application_id(name: "access_global_admin_pages", model_name: "all", application_id: application_id)
    permission_2 = Permission.find_or_create_by_name_and_application_id(name: "access_programs_admin_pages", model_name: "all", application_id: application_id)

    role = Role.find_or_create_by_name_and_application_id(name: "admin_pages_moderator", application_id: application_id)
    role.permissions << permission_1 unless role.permissions.include? permission_1
    role.permissions << permission_2 unless role.permissions.include? permission_2

    permission_6 = Permission.find_or_create_by_name_and_application_id(name: "allow_impersonation", model_name: "all", application_id: application_id)
    impersonate_role = Role.find_or_create_by_name_and_application_id(name: "impersonate_user", application_id: application_id)
    impersonate_role.permissions << permission_6 unless impersonate_role.permissions.include? permission_6


    puts "Assigning admin_pages_moderator and impersonation role to System Admin Group"
    sys_admin_group.roles << role unless sys_admin_group.roles.include? role
    sys_admin_group.roles << impersonate_role unless sys_admin_group.roles.include? impersonate_role
  end

  # Validate rule for each group
  desc "Validate rule for each group"
  task :seed_validate_groups => :environment do
    puts "Validating group rules"
    Group.all.each do |group|
      group.rule_validation
      if !group.errors[:rule].empty?
        message = "Group with id #{group.id} has invalid rule. "
        message +="Name: #{group.name} Rule: #{group.rule} Error: #{group.errors[:rule]}"
        puts message
        begin
          raise(message)
        rescue => e
          D360Core::D360_Logger.error e
        end
        puts "Setting invalid_rule_flag to true for this group"
        group.invalid_rule_flag = true
        group.save
      end
    end
  end

  # Receives a parameter [nci] or [d360]
  desc "Updates DSM_Users group rule to be able to access or not dealer360."
  task "update_dsm_groups", [:group_type] => :environment do |t, args|
    group_type = args[:group_type].downcase if not args[:group_type].nil?
    dsm_group_updated = true
    group_name = 'DSM_Users'

    case group_type
    when 'nci'
      group_rule = 'users.nna = 0 AND users.nna_net = 1 AND users.status = 1'
      create_group_if_present(group_name, group_rule)
    when 'd360'
      # All except DSM Infiniti users will have access to the system
      group_rule = 'users.nna = 0 AND users.nna_net = 1 AND users.status = 1 AND entities.company != \'Infiniti\''
      create_group_if_present(group_name, group_rule)
    else
      dsm_group_updated = false
      puts "Missing or wrong parameter 'nci' or 'd360', group not modified"
    end

    puts "Rule for DSM_Users group for #{group_type} was updated..." if dsm_group_updated
  end

  private

  def create_group_if_present(name, rule)
    group = Group.find_by_name(name)
    if !group.present?
      group = Group.new(:name => name, :advanced_sql_rule => rule)
      group.rule = group.get_rule_from_subparts()
      group.category = Group::CATEGORY[:SYSTEM_ACCESS]
      group.save!
    end
  end
end
