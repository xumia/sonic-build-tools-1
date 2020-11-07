#!/usr/bin/python3

import datetime
import json
import os
import re
import sys
from urllib import request

SERVER = 'https://sonic-jenkins.westus2.cloudapp.azure.com/api/json'
JOB_ATTRIBUITES = 'name,buildable,url,builds[number,status,timestamp,id,result,duration,builtOn]'
JOB_QUERY_PATTERN='?tree=jobs[{JOB_ATTRIBUITES},jobs[{JOB_ATTRIBUITES},jobs[{JOB_ATTRIBUITES}]]]'

def _get_jobs(jenkins_jobs, folder=''):
    result = []
    for job in jenkins_jobs:
        if 'jobs' in job:
            cur_folder = job['name']
            if folder:
                cur_folder = folder + '/' + job['name']
            result += _get_jobs(job['jobs'], cur_folder)
        else:
            job['folder'] = folder
            result.append(job)
    return result

def get_response(url):
    response = request.urlopen(url)
    data=response.read()
    encoding = response.info().get_content_charset('utf-8')
    return data.decode(encoding)

def get_jobs():
    query_url = SERVER + JOB_QUERY_PATTERN.format(JOB_ATTRIBUITES=JOB_ATTRIBUITES)
    text = get_response(query_url)
    js=json.loads(text)
    return _get_jobs(js['jobs'])

def get_upload_job(jobs):
    JOB_NAME='jenkins-log-uploader'
    for job in jobs:
        if job['name'] == JOB_NAME:
            print('The upload job {0} found'.format(JOB_NAME))
            return job
    print('The upload job {0} does not exist'.format(JOB_NAME))
    return None

def get_last_success_time(job):
    t = datetime.datetime(2020,11, 6)
    timestamp = t.timestamp()*1000.0
    if not job or 'builds' not in job:
        return timestamp
    for build in job['builds']:
        if build['result'] == 'SUCCESS' and timestamp < build['timestamp']:
            timestamp = build['timestamp']
    return timestamp

def get_timespan(td):
    return '{0}.{1}:{2}:{3}.{4:0>6d}'.format(td.days, td.seconds//3600, (td.seconds//60)%60, td.seconds%60, td.microseconds)

def get_build_results_by_job(job, et, dt=0):
    results = []
    dump_time = datetime.datetime.fromtimestamp(dt/1000.0)
    if 'builds' not in job:
        return results
    for build in job['builds']:
        result = build['result']
        if result != 'FAILURE' and result != 'SUCCESS' and result != 'ABORTED':
            continue
        end_time = build['timestamp'] + build['duration']
        if end_time <= et:
            continue
        if dt > 0 and end_time >= dt:
            continue
        try:
            timestamp=datetime.datetime.fromtimestamp(build['timestamp']/1000.0)
            complete_timestamp=datetime.datetime.fromtimestamp(end_time/1000.0)
            build_url = job['url'] + str(build['number']) + '/'
            console_url = build_url + 'consoleText'
            print(console_url)
            try:
                output = get_response(console_url)
            except Exception as e:
                if '404' in str(e):
                    print('Not Found: {0}'.format(console_url))
                    continue
            br = {}
            br['Output'] = output
            br['Number'] = build['number']
            br['Url'] = build_url
            br['Name'] = job['name']
            br['Folder'] = job['folder']
            br['BuildOn'] = ""
            if 'buildOn' in build:
                br['BuildOn'] = build['buildOn']
            br['Result'] = result
            br['DumpTime'] = dump_time.isoformat()
            br['Timestamp'] = timestamp.isoformat()
            br['EndTime'] = complete_timestamp.isoformat()
            br['Duration'] = get_timespan(complete_timestamp-timestamp)
            results.append(br)
        except Exception as e:
            print(e)
            continue
    return results

def get_build_results(jobs, dt=0):
    results = []
    upload_job = get_upload_job(jobs)
    timestamp = get_last_success_time(upload_job)
    print('The last build timestamp is {0}'.format(datetime.datetime.fromtimestamp(timestamp/1000.0).isoformat()))
    for job in jobs:
        results += get_build_results_by_job(job, timestamp, dt)
    return results

def get_components_by_build_result(br, dt=0):
    results = []
    dump_time = datetime.datetime.fromtimestamp(dt/1000.0)
    p=re.compile(r'\[([^\]]+)\]\s*\[([^\]]+)\]\s*\[([^\]]+)\]')
    if 'Output' not in br:
        return results
    buildon = None
    if 'BuildOn' in br:
        buildon = br['BuildOn']
    lines = br['Output'].splitlines()
    if not buildon:
        for line in lines:
            if 'Running on ' in line:
                items = line.split('Running on ')
                items = items[1].split(' ')
                buildon = items[0]
                break
        br['BuildOn'] = buildon
    for line in lines:
        line = line.strip()
        if not line.startswith('[') or not line.endswith(']'):
            continue
        match = p.match(line)
        if match:
            groups = match.groups()
            if len(groups) >= 3:
                result = {}
                try:
                    result['Timestamp'] = groups[0].strip()
                    result['Status'] = groups[1].strip()
                    target = groups[2].strip()
                    result['TargetName'] = target.split('/')[-1]
                    result['TargetFullName'] = target
                    result['Number'] = br['Number']
                    result['Name'] = br['Name']
                    result['Folder'] = br['Folder']
                    result['BuildOn'] = buildon
                    result['StartTime'] = br['Timestamp']
                    result['EndTime'] = br['EndTime']
                    result['DumpTime'] = dump_time.isoformat()
                    results.append(result)
                except Exception as e:
                    print(e)
                    continue
    return results

def get_components(brs, dt=0):
    results = []
    for br in brs:
        results += get_components_by_build_result(br, dt)
    return results

def copy_dict(_dict, columns):
    result = {}
    for column in columns:
        result[column] = _dict[column]
    return result

def get_metric_builds(brs):
    results = []
    build_columns = ['Number', 'Url', 'Name', 'Folder', 'BuildOn', 'Result', 'DumpTime', 'Timestamp', 'EndTime', 'Duration']
    for br in brs:
        build = copy_dict(br, build_columns)
        results.append(build)
    return results

def get_mertic_buildoutput(brs):
    results = []
    buildoutput_columns = ['Number', 'Name', 'Folder', 'DumpTime', 'Timestamp', 'EndTime', 'Output']
    for br in brs:
        buildoutput = copy_dict(br, buildoutput_columns)
        results.append(buildoutput)
    return results

def write_metrics(metrics, filepath, msg=''):
    delta = len(metrics) / 100
    count = 0
    next_count = -1
    if not msg:
        msg = filepath
    print('Write {0} metrics to file {1}'.format(len(metrics), filepath))
    with open(filepath, 'w') as f:
        for metric in metrics:
            count = count + 1
            if count > next_count:
                print('{0}/{1} {2}'.format(count, len(metrics), msg))
                next_count = count + delta
            text = json.dumps(metric) + "\n"
            f.writelines(text)

def main():
    timestamp = datetime.datetime.utcnow()
    dt = timestamp.timestamp()*1000
    target_path='./target'
    if not os.path.exists(target_path):
        os.makedirs(target_path)
    file_subfix = timestamp.strftime('%Y-%m-%dT%H%M%S.json')
    component_filename = target_path + "/JenkinsBuildTargets_" + file_subfix
    build_filename = target_path + '/JenkinsBuilds_' + file_subfix
    
    jobs = get_jobs()
    jobs_tmp = jobs
    brs = get_build_results(jobs_tmp, dt)
    components = get_components(brs, dt)
    write_metrics(components, component_filename, 'metric_components')
    metric_builds = get_metric_builds(brs)
    write_metrics(metric_builds, build_filename, 'metric_builds')

if __name__ == "__main__":
    main()
