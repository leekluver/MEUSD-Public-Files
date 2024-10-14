#!/bin/bash

# PiSlides Installation Script
# This script automates the installation of PiSlides on a Raspberry Pi.

# Exit on error
set -e

# Determine the username to use
if [ "$SUDO_USER" ]; then
    USERNAME="$SUDO_USER"
else
    USERNAME="$USER"
fi

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script must be run as root. Use sudo ./install.sh"
        exit 1
    fi
}

# Update and upgrade the system
update_system() {
    echo "Updating system..."
    apt-get update
    apt-get upgrade -y
}

# Install necessary packages
install_packages() {
    echo "Installing necessary packages..."
    apt-get install -y python3-pip python3-venv imagemagick ghostscript lightdm openbox feh curl libpam0g-dev
}

# Create project directory and set permissions
setup_project_directory() {
    echo "Setting up project directory..."
    mkdir -p /opt/PiSlides
    chown $USERNAME:$USERNAME /opt/PiSlides
}

# Set up Flask app structure
setup_flask_app() {
    echo "Setting up Flask app structure..."
    mkdir -p /opt/PiSlides/PiSlides/static
    mkdir -p /opt/PiSlides/PiSlides/templates
    touch /opt/PiSlides/PiSlides/__init__.py
    mkdir -p /opt/PiSlides/instance/sessions
    chown -R $USERNAME:$USERNAME /opt/PiSlides
}

# Write Flask application code
write_flask_app_code() {
    echo "Writing Flask application code..."
    SECRET_KEY=$(python3 -c "import os; print(os.urandom(24).hex())")
    cat << EOF > /opt/PiSlides/PiSlides/__init__.py
from flask import Flask, render_template, request, redirect, url_for, session
import subprocess
import os
import time
from flask_session import Session
import logging
import pam  # Import PAM module

def create_app():
    app = Flask(__name__)
    app.secret_key = '$SECRET_KEY'  # Generated secret key

    # Ensure instance folder exists
    os.makedirs(app.instance_path, exist_ok=True)

    # Flask-Session configuration
    app.config['SESSION_TYPE'] = 'filesystem'
    app.config['SESSION_FILE_DIR'] = os.path.join(app.instance_path, 'sessions')
    app.config['SESSION_PERMANENT'] = True
    app.config['PERMANENT_SESSION_LIFETIME'] = 300  # 5-minute session timeout

    # Security settings for cookies
    app.config['SESSION_COOKIE_SECURE'] = False  # Allow HTTP since HTTPS is not used
    app.config['SESSION_COOKIE_HTTPONLY'] = True
    app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'

    # Initialize Flask-Session
    Session(app)

    # Configure logging
    logging.basicConfig(filename='/opt/PiSlides/logs/app.log', level=logging.INFO)

    @app.before_request
    def session_management():
        session.permanent = True
        session.modified = True

    @app.route('/')
    def home():
        if 'logged_in' in session:
            if time.time() - session.get('last_activity', 0) > app.permanent_session_lifetime.total_seconds():
                return redirect(url_for('logout'))
            else:
                session['last_activity'] = time.time()
                return redirect(url_for('dashboard'))
        return render_template('login.html')

    @app.route('/login', methods=['GET', 'POST'])
    def login():
        if request.method == 'POST':
            username = request.form['username']
            password = request.form['password']

            if authenticate_user(username, password):
                session['logged_in'] = True
                session['username'] = username
                session['last_activity'] = time.time()
                return redirect(url_for('dashboard'))
            else:
                return "Invalid credentials", 403

        return render_template('login.html')

    def authenticate_user(username, password):
        p = pam.pam()
        return p.authenticate(username, password)

    @app.route('/dashboard')
    def dashboard():
        if 'logged_in' not in session:
            return redirect(url_for('login'))

        link = ""
        delay = ""  # Set delay to an empty string initially

        # Retrieve link if it has been saved before
        link_file_path = os.path.join(app.instance_path, 'slideshow_link.txt')
        if os.path.exists(link_file_path):
            with open(link_file_path, 'r') as f:
                link = f.read().strip()

        # Retrieve delay if it has been saved before
        delay_file_path = os.path.join(app.instance_path, 'slideshow_delay.txt')
        if os.path.exists(delay_file_path):
            with open(delay_file_path, 'r') as f:
                delay = f.read().strip()

        return render_template('dashboard.html', slideshow_link=link, slideshow_delay=delay)

    @app.route('/save_link', methods=['POST'])
    def save_link():
        if 'logged_in' not in session:
            return redirect(url_for('login'))

        # Get the Google Slides link and delay value from the form submission
        link = request.form['slideshow_link']
        delay = request.form['slideshow_delay']

        # Save slideshow link to a file (for later use)
        link_file_path = os.path.join(app.instance_path, 'slideshow_link.txt')
        with open(link_file_path, 'w') as f:
            f.write(link)

        # Save slideshow delay to a configuration file
        delay_config_path = os.path.join(app.instance_path, 'slideshow_delay.txt')
        with open(delay_config_path, 'w') as f:
            f.write(delay)

        # Run the download_and_convert.sh script to update images
        try:
            with open('/opt/PiSlides/logs/download_and_convert.log', 'a') as log_file:
                subprocess.Popen(['/opt/PiSlides/download_and_convert.sh'], stdout=log_file, stderr=log_file)
        except Exception as e:
            logging.error(f"Failed to run download_and_convert.sh script: {e}")

        # Kill any running feh processes
        try:
            subprocess.run(['pkill', 'feh'], check=True)
        except subprocess.CalledProcessError:
            logging.info("No running feh process found to kill.")

        # Use nohup to restart feh directly
        try:
            subprocess.Popen(['nohup', '/opt/PiSlides/start_feh.sh', '&'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            logging.info("Successfully restarted feh using nohup.")
        except Exception as e:
            logging.error(f"Failed to restart feh: {e}")

        # Redirect back to the dashboard after saving
        return redirect(url_for('dashboard'))

    @app.route('/logout')
    def logout():
        session.clear()
        return redirect(url_for('home'))

    return app

EOF
    chown $USERNAME:$USERNAME /opt/PiSlides/PiSlides/__init__.py
}

# Create application entry point (wsgi.py)
create_wsgi_entry_point() {
    echo "Creating application entry point..."
    cat << 'EOF' > /opt/PiSlides/wsgi.py
from PiSlides import create_app

app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF
    chown $USERNAME:$USERNAME /opt/PiSlides/wsgi.py
}

# Set up virtual environment and install Python packages
setup_virtualenv() {
    echo "Setting up virtual environment..."
    su - $USERNAME -c "
        cd /opt/PiSlides
        python3 -m venv venv
        source venv/bin/activate
        pip install --upgrade pip
        pip install Flask Flask-Session pam six
        deactivate
    "
}

# Create logs directory
create_logs_directory() {
    echo "Creating logs directory..."
    mkdir -p /opt/PiSlides/logs
    chown $USERNAME:$USERNAME /opt/PiSlides/logs
    chmod 755 /opt/PiSlides/logs
}

# Create HTML templates
create_html_templates() {
    echo "Creating HTML templates..."
    mkdir -p /opt/PiSlides/PiSlides/templates

    # Create login.html
    cat << 'EOL' > /opt/PiSlides/PiSlides/templates/login.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>PiSlides Login</title>
    <style>
        @keyframes gradientAnimation {
            0% { background-position: 0% 50%; }
            50% { background-position: 100% 50%; }
            100% { background-position: 0% 50%; }
        }
        body {
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            background: linear-gradient(135deg, #6dd5ed, #2193b0, #f7797d);
            background-size: 200% 200%;
            animation: gradientAnimation 10s ease infinite;
            font-family: Arial, sans-serif;
            margin: 0;
        }
        .login-container {
            background: rgba(255, 255, 255, 0.8);
            padding: 40px;
            border-radius: 15px;
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2);
            backdrop-filter: blur(10px);
            -webkit-backdrop-filter: blur(10px);
            width: 300px;
            text-align: center;
        }
        h2 {
            margin-bottom: 20px;
            color: #333;
        }
        label {
            font-weight: bold;
            color: #555;
        }
        input[type="text"],
        input[type="password"] {
            width: 100%;
            padding: 10px;
            margin: 10px 0 20px 0;
            border: 1px solid #ccc;
            border-radius: 5px;
        }
        button {
            width: 100%;
            padding: 10px;
            background-color: #007bff;
            color: white;
            border: none;
            border-radius: 5px;
            font-weight: bold;
            cursor: pointer;
            transition: background-color 0.3s;
        }
        button:hover {
            background-color: #0056b3;
        }
        .logo {
            width: 150px;
            margin-bottom: 20px;
        }
    </style>
</head>
<body>
    <div class="login-container">
        <img src="https://raw.githubusercontent.com/leekluver/MEUSD-Public-Files/main/PiSlides.png" alt="PiSlides Logo" class="logo">
        <h2>Login</h2>
        <form method="POST" action="/login">
            <label for="username">Username:</label>
            <input type="text" id="username" name="username" required>
            <label for="password">Password:</label>
            <input type="password" id="password" name="password" required>
            <button type="submit">Login</button>
        </form>
    </div>
</body>
</html>
EOL

    # Create dashboard.html
    cat << 'EOL' > /opt/PiSlides/PiSlides/templates/dashboard.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Dashboard</title>
    <style>
        @keyframes gradientAnimation {
            0% { background-position: 0% 50%; }
            50% { background-position: 100% 50%; }
            100% { background-position: 0% 50%; }
        }
        body {
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            background: linear-gradient(135deg, #6dd5ed, #2193b0, #f7797d);
            background-size: 200% 200%;
            animation: gradientAnimation 10s ease infinite;
            font-family: Arial, sans-serif;
            margin: 0;
        }
        .dashboard-container {
            background: rgba(255, 255, 255, 0.8);
            padding: 60px;
            border-radius: 15px;
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2);
            backdrop-filter: blur(10px);
            -webkit-backdrop-filter: blur(10px);
            width: 600px;
            text-align: center;
        }
        .logo {
            width: 150px;
            margin-bottom: 20px;
        }
        h2 {
            font-size: 2em;
            margin-bottom: 30px;
            color: #333;
        }
        label {
            font-weight: bold;
            color: #555;
        }
        input[type="text"] {
            width: 100%;
            font-size: 1.1em;
            padding: 10px;
            margin: 10px 0 20px 0;
            border: 1px solid #ccc;
            border-radius: 5px;
        }
        button {
            width: 100%;
            padding: 10px;
            background-color: #007bff;
            color: white;
            border: none;
            border-radius: 5px;
            font-weight: bold;
            cursor: pointer;
            transition: background-color 0.3s;
        }
        button:hover {
            background-color: #0056b3;
        }
        a {
            display: block;
            margin-top: 20px;
            color: #007bff;
            text-decoration: none;
            font-weight: bold;
            transition: color 0.3s;
        }
        a:hover {
            color: #0056b3;
        }
        .instructions img {
            width: 100%;
            border-radius: 10px;
            margin-top: 15px;
            box-shadow: 0 4px 16px rgba(0, 0, 0, 0.2);
        }
    </style>
</head>
<body>
    <div class="dashboard-container">
        <img src="https://raw.githubusercontent.com/leekluver/MEUSD-Public-Files/main/PiSlides.png" alt="PiSlides Logo" class="logo">
        <h2>Let's Set Up the Digital Sign Using Google Slides</h2>

        <div class="instructions">
            <h3>How to Get the Google Slides Link</h3>
            <p>To use the slideshow feature, you need to provide a shareable link to your Google Slides presentation. Follow these steps:</p>
            <ol style="text-align: left;">
                <li>Open your Google Slides presentation.</li>
                <li>Click on the "Share" button in the top right corner.</li>
                <li>Under "Get Link," click on "Change to anyone with the link."</li>
                <li>Copy the link provided and paste it into the field below.</li>
            </ol>
            <p>Ensure that the link is set to allow anyone with the link to view the presentation so it can be accessed properly.</p>
        </div>

        <form method="POST" action="/save_link">
            <label for="slideshow_link">Google Slides Link:</label>
            <input type="text" id="slideshow_link" name="slideshow_link" value="{{ slideshow_link }}" required><br><br>

            <label for="slideshow_delay">Auto-Advance Slides:</label>
            <select id="slideshow_delay" name="slideshow_delay" required>
                <option value="" {% if slideshow_delay is none or slideshow_delay == "" %}selected{% endif %}>Select slideshow delay...</option>
                <option value="1" {% if slideshow_delay == "1" %}selected{% endif %}>Every 1 second</option>
                <option value="2" {% if slideshow_delay == "2" %}selected{% endif %}>Every 2 seconds</option>
                <option value="3" {% if slideshow_delay == "3" %}selected{% endif %}>Every 3 seconds</option>
                <option value="5" {% if slideshow_delay == "5" %}selected{% endif %}>Every 5 seconds</option>
                <option value="10" {% if slideshow_delay == "10" %}selected{% endif %}>Every 10 seconds(Default)</option>
                <option value="15" {% if slideshow_delay == "15" %}selected{% endif %}>Every 15 seconds</option>
                <option value="30" {% if slideshow_delay == "30" %}selected{% endif %}>Every 30 seconds</option>
                <option value="60" {% if slideshow_delay == "60" %}selected{% endif %}>Every minute</option>
            </select><br><br>

            <button type="submit">Save</button>
        </form>

        {% if slideshow_link %}
        <p>Current saved link: <a href="{{ slideshow_link }}" target="_blank">Open Google Slide Show</a></p>
        {% else %}
        <p>No link saved yet.</p>
        {% endif %}

        <a href="/logout">Logout</a>
    </div>
</body>
</html>
EOL

    chown -R $USERNAME:$USERNAME /opt/PiSlides/PiSlides/templates
}

# Set Flask app to start on boot
setup_systemd_service() {
    echo "Setting up systemd service for Flask app..."
    cat << EOF > /etc/systemd/system/pislides.service
[Unit]
Description=PiSlides Flask Application
After=network.target

[Service]
User=$USERNAME
WorkingDirectory=/opt/PiSlides
ExecStart=/opt/PiSlides/venv/bin/python /opt/PiSlides/wsgi.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    echo "Enabling and starting the pislides service..."
    systemctl daemon-reload
    systemctl enable pislides
    systemctl start pislides
}

# Clear sessions on reboot
setup_rc_local() {
    echo "Setting up rc.local to clear sessions on reboot..."
    if [ ! -f /etc/rc.local ]; then
        echo '#!/bin/sh -e' > /etc/rc.local
        chmod +x /etc/rc.local
    fi
    sed -i '/^exit 0/d' /etc/rc.local
    echo "rm -rf /opt/PiSlides/instance/sessions/*" >> /etc/rc.local
    echo "exit 0" >> /etc/rc.local
}

# Update ImageMagick policy
update_imagemagick_policy() {
    echo "Updating ImageMagick policy..."
    cat << 'EOF' > /opt/PiSlides/update_imagemagick_policy.sh
#!/bin/bash

# Define the path to ImageMagick policy.xml
POLICY_FILE="/etc/ImageMagick-6/policy.xml"
if [[ ! -f "$POLICY_FILE" ]]; then
    POLICY_FILE="/etc/ImageMagick/policy.xml"
fi

# Update policy.xml to allow PDF conversions
if [[ -f "$POLICY_FILE" ]]; then
    echo "Updating ImageMagick policy to allow PDF conversions..."
    sudo sed -i 's/<policy domain="coder" rights="none" pattern="PDF" \/>/<policy domain="coder" rights="read|write" pattern="PDF" \/>/' "$POLICY_FILE"
else
    echo "ImageMagick policy.xml file not found!"
    exit 1
fi

echo "ImageMagick policy updated successfully!"
EOF
    chmod +x /opt/PiSlides/update_imagemagick_policy.sh
    /opt/PiSlides/update_imagemagick_policy.sh
}

# Create download_and_convert.sh script
create_download_convert_script() {
    echo "Creating download_and_convert.sh script..."
    cat << 'EOF' > /opt/PiSlides/download_and_convert.sh
#!/bin/bash

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PDF_FILE="/opt/PiSlides/instance/slideshow.pdf"
IMAGE_DIR="/opt/PiSlides/images"
TEMP_DIR="/opt/PiSlides/temp_images"
PLAYLIST_FILE="/opt/PiSlides/playlist.txt"
LINK_FILE="/opt/PiSlides/instance/slideshow_link.txt"
OFFLINE_IMAGE="/opt/PiSlides/images/offline.png"
SPLASH_IMAGE="/opt/PiSlides/images/splash.png"
SPLASH_BASE="/opt/PiSlides/splash_base.png"
DELETE_MARK=()  # Array to hold images marked for deletion

# Create directories if they don't exist
mkdir -p "$IMAGE_DIR"
mkdir -p "$TEMP_DIR"

# Function to check if the system is online
is_online() {
    # Ping Google's DNS (8.8.8.8) and MEUSD DNS (10.0.0.5)
    # Success if at least one of the servers responds
    if ping -c 3 -i 2 -q 8.8.8.8 &> /dev/null || ping -c 3 -i 2 -q 10.0.0.5 &> /dev/null; then
        return 0  # System is online if at least one server responds
    else
        return 1  # System is offline if neither server responds
    fi
}

# Function to create an offline mode image
create_offline_image() {
    convert -size 1920x1080 xc:white -gravity center \
    -pointsize 50 -fill black -annotate +0+0 \
    "The system is currently running in offline mode.\nYou will not receive updates until you are back online." \
    "$OFFLINE_IMAGE"
}

# Function to create the splash image with IP address
create_splash_image() {
    # Download the base splash image if it doesn't exist
    if [[ ! -f "$SPLASH_BASE" ]]; then
        wget -O "$SPLASH_BASE" "https://raw.githubusercontent.com/leekluver/MEUSD-Public-Files/main/PiSlidesSplash.png"
    fi

    # Get the IP address
    IP_ADDRESS=$(hostname -I | awk '{print $1}')

    # Overlay the IP address onto the splash image
    convert "$SPLASH_BASE" -gravity South -pointsize 50 -fill black \
    -annotate +0+100 "http://$IP_ADDRESS:5000" "$SPLASH_IMAGE"
}

# Check if the system is online
if is_online; then
    echo "System is online, proceeding with download..."

    # Remove the offline image from the playlist if present
    if grep -q "$OFFLINE_IMAGE" "$PLAYLIST_FILE"; then
        echo "Removing offline image from playlist..."
        sed -i "/$OFFLINE_IMAGE/d" "$PLAYLIST_FILE"
    fi

    # Read the slideshow link
    if [[ ! -f "$LINK_FILE" ]]; then
        echo "Slideshow link file not found!"

        # Since there is no slideshow link, create the splash image
        create_splash_image

        # Update the playlist to show the splash image
        echo "$SPLASH_IMAGE" > "$PLAYLIST_FILE"
        exit 0
    fi

    SLIDESHOW_LINK=$(cat "$LINK_FILE")
    echo "Slideshow link is: $SLIDESHOW_LINK"

    # Modify the link for PDF export
    PDF_LINK="${SLIDESHOW_LINK/\/edit*/\/export\/pdf}"
    echo "Modified link for PDF export: $PDF_LINK"

    # Download the PDF
    echo "Downloading PDF from $PDF_LINK..."
    curl -L -o "$PDF_FILE" "$PDF_LINK"

    if [[ $? -eq 0 ]]; then
        echo "PDF downloaded successfully and saved to $PDF_FILE"
    else
        echo "Failed to download PDF"
        exit 1
    fi

    # Clear out the temp directory
    rm -f "$TEMP_DIR"/*.png

    # Convert each page of the PDF into a separate image in the temp directory
    convert -density 150 "$PDF_FILE" "$TEMP_DIR/slide-%03d.png"

    if [[ $? -eq 0 ]]; then
        echo "Conversion successful!"
    else
        echo "Failed to convert PDF to images."
        exit 1
    fi

    # Mark old images for deletion
    echo "Marking old images for deletion..."
    for existing_image in "$IMAGE_DIR"/*.png; do
        image_filename=$(basename "$existing_image")
        if [[ ! -f "$TEMP_DIR/$image_filename" ]]; then
            echo "Marking $existing_image for deletion."
            DELETE_MARK+=("$existing_image")
        fi
    done

    # Move new images to the main image directory
    echo "Moving new images to the image directory..."
    for temp_image in "$TEMP_DIR"/*.png; do
        image_filename=$(basename "$temp_image")
        echo "Moving $temp_image to $IMAGE_DIR/$image_filename"
        mv "$temp_image" "$IMAGE_DIR/$image_filename"
    done

    # Delete images marked for deletion
    echo "Deleting marked images..."
    for image_to_delete in "${DELETE_MARK[@]}"; do
        if [[ -f "$image_to_delete" ]]; then
            echo "Deleting $image_to_delete"
            rm "$image_to_delete"
        fi
    done

    # Update the playlist with the new images
    echo "Updating playlist..."
    > "$PLAYLIST_FILE"  # Clear the playlist file
    for image in "$IMAGE_DIR"/*.png; do
        echo "$image" >> "$PLAYLIST_FILE"
        echo "Added $image to playlist"
    done

    echo "Playlist updated successfully!"

else
    echo "System is offline, appending offline mode image..."

    # Create the offline mode image if it doesn't already exist
    if [[ ! -f "$OFFLINE_IMAGE" ]]; then
        create_offline_image
    fi

    # Append the offline image to the playlist if it's not already there
    if ! grep -q "$OFFLINE_IMAGE" "$PLAYLIST_FILE"; then
        echo "$OFFLINE_IMAGE" >> "$PLAYLIST_FILE"
        echo "Offline image added to playlist."
    fi
fi

# If no images are in the images folder, create the splash image
if [[ -z "$(ls -A $IMAGE_DIR/*.png 2>/dev/null)" ]]; then
    echo "No images found in $IMAGE_DIR, creating splash image..."
    create_splash_image
    echo "$SPLASH_IMAGE" > "$PLAYLIST_FILE"
fi

echo "Script execution completed!"

EOF

    chmod +x /opt/PiSlides/download_and_convert.sh
    chown $USERNAME:$USERNAME /opt/PiSlides/download_and_convert.sh
}

# Set up cron job
setup_cron_job() {
    echo "Setting up cron job to run download_and_convert.sh every 5 minutes..."
    sudo -u $USERNAME bash -c '(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/PiSlides/download_and_convert.sh >> /opt/PiSlides/logs/cron_job.log 2>&1") | crontab -'
}

# Set up autologin for Openbox
setup_autologin_desktop() {
    echo "Creating and running setup_autologin_desktop.sh..."
    cat << EOF > /opt/PiSlides/setup_autologin_desktop.sh
#!/bin/bash

# Function to enable desktop autologin for the user with Openbox
enable_autologin() {
    USER="$USERNAME"

    # Ensure LightDM is installed
    if ! dpkg -l | grep -q lightdm; then
        echo "LightDM is not installed. Installing..."
        sudo apt-get update
        sudo apt-get install lightdm -y
    fi

    # Set systemd to boot into graphical.target
    echo "Setting boot to graphical.target..."
    sudo systemctl --quiet set-default graphical.target

    # Configure autologin
    echo "Configuring autologin for user \$USER..."
    sudo mkdir -p /etc/lightdm/lightdm.conf.d
    sudo bash -c "cat > /etc/lightdm/lightdm.conf.d/20-autologin.conf << EOF2
[Seat:*]
autologin-user=\$USER
autologin-session=openbox
EOF2"

    # Create .xsession file to start Openbox
    echo "Creating .xsession file to start Openbox..."
    echo "#!/bin/bash
xset s off          # Disable screen saver
xset -dpms          # Disable DPMS (Energy Star) features
xset s noblank      # Disable screen blanking
exec openbox-session" > /home/\$USER/.xsession
    chmod +x /home/\$USER/.xsession
    chown \$USER:\$USER /home/\$USER/.xsession

    # Reload systemd daemon
    echo "Reloading systemd..."
    sudo systemctl daemon-reload

    echo "Autologin configuration complete. Please reboot your Raspberry Pi."
}

enable_autologin
EOF

    chmod +x /opt/PiSlides/setup_autologin_desktop.sh
    /opt/PiSlides/setup_autologin_desktop.sh
}

# Create start_feh.sh script
create_start_feh_script() {
    echo "Creating start_feh.sh script..."
    cat << 'EOF' > /opt/PiSlides/start_feh.sh
#!/bin/bash

# Path to the playlist
PLAYLIST_FILE="/opt/PiSlides/playlist.txt"
DELAY_CONFIG_FILE="/opt/PiSlides/instance/slideshow_delay.txt"

export DISPLAY=:0

# Read the slideshow delay from the configuration file
if [[ -f "$DELAY_CONFIG_FILE" ]]; then
    SLIDESHOW_DELAY=$(cat "$DELAY_CONFIG_FILE")
else
    SLIDESHOW_DELAY=10  
fi

# Loop to keep restarting feh if it crashes or exits
while true; do
    feh --fullscreen --reload 3 --slideshow-delay "$SLIDESHOW_DELAY" --stretch --auto-zoom --filelist "$PLAYLIST_FILE" --hide-pointer
    sleep 2  # Slight delay before restarting if it crashes
done
EOF

    chmod +x /opt/PiSlides/start_feh.sh
    chown $USERNAME:$USERNAME /opt/PiSlides/start_feh.sh
}

# Prevent screen blanking
prevent_screen_blanking() {
    echo "Configuring system to prevent screen blanking..."
    # Modify LightDM configuration
    LIGHTDM_CONF="/etc/lightdm/lightdm.conf"
    if grep -q '^xserver-command=X -s 0 dpms' "$LIGHTDM_CONF"; then
        echo "LightDM already configured to prevent screen blanking."
    else
        echo "Updating LightDM configuration..."
        sed -i '/^#xserver-command=X$/d' "$LIGHTDM_CONF"
        sed -i '/^xserver-command=X -s 0 dpms$/d' "$LIGHTDM_CONF"
        if grep -q '^\[Seat:\*\]' "$LIGHTDM_CONF"; then
            sed -i '/^\[Seat:\*\]/a xserver-command=X -s 0 dpms' "$LIGHTDM_CONF"
        else
            echo "[Seat:*]" >> "$LIGHTDM_CONF"
            echo "xserver-command=X -s 0 dpms" >> "$LIGHTDM_CONF"
        fi
    fi

    # Modify Openbox autostart
    su - $USERNAME -c "
        mkdir -p ~/.config/openbox
        AUTOSTART_FILE=~/.config/openbox/autostart
        if ! grep -q '/opt/PiSlides/start_feh.sh &' \"\$AUTOSTART_FILE\"; then
            echo '/opt/PiSlides/start_feh.sh &' >> \"\$AUTOSTART_FILE\"
        fi
    "
}

# Modify PAM configuration to comment out pam_group.so in both SSH and login
modify_pam_sshd() {
    echo "Modifying PAM configuration for SSHD and login..."

    PAM_SSHD_FILE="/etc/pam.d/sshd"
    PAM_LOGIN_FILE="/etc/pam.d/login"

    # Check and comment out pam_group.so in SSHD configuration
    if grep -q "^auth\s\+optional\s\+pam_group.so" "$PAM_SSHD_FILE"; then
        sudo sed -i 's/^auth\s\+optional\s\+pam_group.so/# &/' "$PAM_SSHD_FILE"
        echo "Commented out pam_group.so in $PAM_SSHD_FILE"
    else
        echo "pam_group.so is not present in $PAM_SSHD_FILE or already commented."
    fi

    # Check and comment out pam_group.so in login configuration
    if grep -q "^auth\s\+optional\s\+pam_group.so" "$PAM_LOGIN_FILE"; then
        sudo sed -i 's/^auth\s\+optional\s\+pam_group.so/# &/' "$PAM_LOGIN_FILE"
        echo "Commented out pam_group.so in $PAM_LOGIN_FILE"
    else
        echo "pam_group.so is not present in $PAM_LOGIN_FILE or already commented."
    fi

    # Restart SSH service to apply changes
    echo "Restarting SSH service..."
    sudo systemctl restart ssh
}


# Reboot system
reboot_system() {
    echo "Installation complete. The system needs to reboot."
    read -p "Do you want to reboot now? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        reboot
    else
        echo "Please reboot the system manually to apply all changes."
    fi
}

modify_config_txt() {
    CONFIG_FILE="/boot/firmware/config.txt"

    # Check and comment out dtoverlay=vc4-fkms-v3d if present
    if grep -q "^dtoverlay=vc4-fkms-v3d" "$CONFIG_FILE"; then
        sudo sed -i 's/^dtoverlay=vc4-fkms-v3d/# &/' "$CONFIG_FILE"
        echo "Commented out dtoverlay=vc4-fkms-v3d in $CONFIG_FILE"
    else
        echo "dtoverlay=vc4-fkms-v3d is not present or already commented."
    fi

    # Check and comment out dtoverlay=vc4-kms-v3d if present
    if grep -q "^dtoverlay=vc4-kms-v3d" "$CONFIG_FILE"; then
        sudo sed -i 's/^dtoverlay=vc4-kms-v3d/# &/' "$CONFIG_FILE"
        echo "Commented out dtoverlay=vc4-kms-v3d in $CONFIG_FILE"
    else
        echo "dtoverlay=vc4-kms-v3d is not present or already commented."
    fi
}

# Reboot system
reboot_system() {
    echo "Changes made to config.txt. The system needs to reboot."
    read -p "Do you want to reboot now? [Y/n] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        sudo reboot
    else
        echo "Please reboot the system manually to apply all changes."
    fi
}


# Main installation function
main() {
    check_root
    update_system
    install_packages
    setup_project_directory
    setup_flask_app
    write_flask_app_code
    create_wsgi_entry_point
    setup_virtualenv
    create_logs_directory
    create_html_templates
	modify_pam_sshd
    setup_systemd_service
    setup_rc_local
    update_imagemagick_policy
    create_download_convert_script
    setup_cron_job
    setup_autologin_desktop
    create_start_feh_script
    prevent_screen_blanking
	modify_config_txt
	
	echo "Running download_and_convert.sh script for initial setup..."
    sudo -u $USERNAME /opt/PiSlides/download_and_convert.sh
	
    reboot_system
}

main
