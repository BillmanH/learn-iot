import os

from flask import Flask, render_template



app = Flask(__name__)
app.secret_key = '[keep it secret]'
static_dir = os.path.join(os.path.dirname(__file__), 'static')


@app.route('/')
def index():
    return render_template('index.html')


if __name__ == '__main__':
    app.jinja_env.auto_reload = True
    app.config['TEMPLATES_AUTO_RELOAD'] = True
    app.run(debug=True)