from flask import Flask, jsonify
import mysql.connector
import os
import time

app = Flask(__name__)

def get_db():
    retries = 5
    while retries > 0:
        try:
            return mysql.connector.connect(
                host=os.environ.get("DB_HOST", "mysql-service"),
                user=os.environ.get("DB_USER", "root"),
                password=os.environ.get("DB_PASS", "rootpassword"),
                database="results"
            )
        except mysql.connector.Error:
            retries -= 1
            time.sleep(3)
    raise Exception("Cannot connect to database after 5 retries")

@app.route('/result/<name>')
def get_result(name):
    try:
        db = get_db()
        cursor = db.cursor()
        cursor.execute("SELECT name, marks FROM students WHERE name=%s", (name,))
        row = cursor.fetchone()
        cursor.close()
        db.close()
        if row:
            return jsonify({"name": row[0], "marks": row[1]})
        return jsonify({"error": "Student not found"}), 404
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/health')
def health():
    return jsonify({"status": "ok"}), 200

@app.route('/init-db')
def init_db():
    try:
        db = get_db()
        cursor = db.cursor()
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS students (
                name VARCHAR(100) PRIMARY KEY,
                marks INT NOT NULL
            )
        """)
        cursor.execute("INSERT IGNORE INTO students (name, marks) VALUES ('Alice', 92)")
        cursor.execute("INSERT IGNORE INTO students (name, marks) VALUES ('Bob', 78)")
        cursor.execute("INSERT IGNORE INTO students (name, marks) VALUES ('Charlie', 85)")
        cursor.execute("INSERT IGNORE INTO students (name, marks) VALUES ('Diana', 95)")
        cursor.execute("INSERT IGNORE INTO students (name, marks) VALUES ('Eve', 88)")
        db.commit()
        cursor.close()
        db.close()
        return jsonify({"status": "Database initialized with sample data"}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
