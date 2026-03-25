import { exec } from 'child_process';
import path from 'path';

// Start your Next.js server
exec('npm start', { cwd: '/home/bridgebox/bridge-box-scorer' }, (err, stdout, stderr) => {
    if (err) console.error(err);
    console.log(stdout);
});
